`timescale 1ns/1ps
// top_fpga_gemm_ws.sv - Weight-stationary GEMM wrapper (tiled controller + file-backed memories)
module top_fpga_gemm_ws #(
    parameter int N_PE    = 16,
    parameter int TILE_K  = 16,
    parameter int N_TOTAL = 128,
    parameter int K_TOTAL = N_TOTAL,
    parameter int DATA_W  = 16,
    parameter int ACC_W   = 48
)(
    input  logic clk,
    input  logic rst,
    input  logic start,
    output logic done_led
);

    localparam int NT = N_TOTAL / N_PE;
    localparam int KT = K_TOTAL / TILE_K;
    localparam int A_DEPTH = N_TOTAL * K_TOTAL;
    localparam int B_DEPTH = K_TOTAL * N_TOTAL;
    localparam int C_DEPTH = N_TOTAL * N_TOTAL;

    // Memories
(* ram_style = "block" *)
logic signed [DATA_W-1:0] memA [0:A_DEPTH-1];

(* ram_style = "block" *)
logic signed [DATA_W-1:0] memB [0:B_DEPTH-1];

(* ram_style = "block" *)
logic signed [ACC_W-1:0]  memC [0:C_DEPTH-1];


    // File load at start (optional initial set)
    // synthesis translate_off
    initial begin
        // if you prefer to load only via TB, you may remove these two lines
        if ($fopen("a_flat.mem","r") != 0) $readmemh("a_flat.mem", memA);
        if ($fopen("b_flat.mem","r") != 0) $readmemh("b_flat.mem", memB);
        $display("A_flat[0..7] = %h %h %h %h %h %h %h %h",
                 memA[0],memA[1],memA[2],memA[3],memA[4],memA[5],memA[6],memA[7]);
        $display("B_flat[0..7] = %h %h %h %h %h %h %h %h",
                 memB[0],memB[1],memB[2],memB[3],memB[4],memB[5],memB[6],memB[7]);
    end
    // synthesis translate_on

    function automatic int a_idx(int r,int k); return r*K_TOTAL+k; endfunction
    function automatic int b_idx(int k,int c); return k*N_TOTAL+c; endfunction
    function automatic int c_idx(int r,int c); return r*N_TOTAL+c; endfunction

    // DUT signals (match top_nxn_weight_stationary)
    logic load_w;
    logic signed [DATA_W-1:0] B_col [0:N_PE-1][0:TILE_K-1];
    logic signed [DATA_W-1:0] a_left_row [0:N_PE-1];
    logic a_valid_row [0:N_PE-1];
    logic a_last_row  [0:N_PE-1];

    logic signed [ACC_W-1:0] emit [0:N_PE-1][0:N_PE-1];
    logic ev [0:N_PE-1][0:N_PE-1];

    // Instantiate the weight-stationary core (names MUST match)
    top_nxn_weight_stationary #(
        .N(N_PE), .K(TILE_K), .DATA_W(DATA_W), .ACC_W(ACC_W)
    ) dut_core (
        .clk(clk), .rst(rst),
        .load_w(load_w),
        .B_col(B_col),
        .a_left_row(a_left_row),
        .a_valid_row(a_valid_row),
        .a_last_row(a_last_row),
        .emit(emit),
        .ev(ev)
    );

    // FSM and controller variables
    typedef enum logic [2:0] {S_IDLE,S_LOAD_W,S_WAIT,S_STREAM,S_DRAIN,S_NEXT,S_DONE} state_t;
    state_t st;
    int tr,tc,tk,t,drain;
    localparam int T_END = (TILE_K-1)+(N_PE-1);

    // Load weights for current tile column (blocking task writes into B_col)
    task automatic load_B_tile(int tc_i,int tk_i);
        for(int j=0;j<N_PE;j++)
            for(int kk=0;kk<TILE_K;kk++)
                B_col[j][kk]=memB[b_idx(tk_i*TILE_K+kk,tc_i*N_PE+j)];
    endtask

    // Drive A rows for a time t (writes staged next values -> registered below)
    task automatic drive_A_wave(int tr_i,int tk_i,int t_i);
        for(int i=0;i<N_PE;i++) begin
            int k_idx=t_i-i;
            if(k_idx>=0 && k_idx<TILE_K) begin
                a_left_row[i]=memA[a_idx(tr_i*N_PE+i,tk_i*TILE_K+k_idx)];
                a_valid_row[i]=1;
                a_last_row[i]=(k_idx==TILE_K-1);
            end else begin
                a_left_row[i]='0;
                a_valid_row[i]=0;
                a_last_row[i]=0;
            end
        end
    endtask

    // Capture outputs synchronously and accumulate across tk tiles
    always_ff @(posedge clk) begin
        if (!rst) begin
            for(int i=0;i<N_PE;i++)
                for(int j=0;j<N_PE;j++)
                    if(ev[i][j]) begin
                       automatic int r_abs=tr*N_PE+i;
                       automatic int c_abs=tc*N_PE+j;
                       automatic int idx=c_idx(r_abs,c_abs);
                        if(tk==0) memC[idx]<=emit[i][j];
                        else      memC[idx]<=memC[idx]+emit[i][j];
                    end
        end
    end

    // FSM (next-state style)
       // FSM (next-state style) - corrected: use blocking '=' for automatic locals
    always_ff @(posedge clk) begin
        if (rst) begin
            st      <= S_IDLE;
            tr      <= 0;
            tc      <= 0;
            tk      <= 0;
            t       <= 0;
            drain   <= 0;
            load_w  <= 0;
            done_led<= 0;
            for (int i=0;i<N_PE;i++) begin
                a_left_row[i] <= '0;
                a_valid_row[i] <= 0;
                a_last_row[i] <= 0;
            end
        end else begin
            // automatic locals for next-state computation (use blocking '=' for them)
            automatic state_t next_st = st;
            automatic int next_tr = tr;
            automatic int next_tc = tc;
            automatic int next_tk = tk;
            automatic int next_t  = t;
            automatic int next_drain = drain;
            automatic logic next_load_w = 1'b0;
            automatic logic next_done = done_led;

            case (st)
                S_IDLE: begin
                    next_done = 1'b0;
                    if (start) begin
                        // clear memC synchronously
                        for (int r0 = 0; r0 < N_TOTAL; r0 = r0 + 1)
                            for (int c0 = 0; c0 < N_TOTAL; c0 = c0 + 1)
                                memC[c_idx(r0,c0)] <= '0;
                        next_tr = 0;
                        next_tc = 0;
                        next_tk = 0;
                        next_st = S_LOAD_W;
                    end
                end

                S_LOAD_W: begin
                    load_B_tile(tc, tk);
                    next_t = 0;
                    next_st = S_WAIT;
                end

                S_WAIT: begin
                    next_load_w = 1'b1;
                    next_st = S_STREAM;
                end

                S_STREAM: begin
                    drive_A_wave(tr, tk, t);
                    if (t == T_END) begin
                        next_t = 0;
                        next_drain = N_PE;
                        next_st = S_DRAIN;
                    end else begin
                        next_t = t + 1;
                    end
                end

                S_DRAIN: begin
                    // zero inputs while draining
                    for (int i = 0; i < N_PE; i = i + 1) begin
                        a_left_row[i]  <= '0;    // these are registers - we keep nonblocking for direct outputs
                        a_valid_row[i] <= 1'b0;
                        a_last_row[i]  <= 1'b0;
                    end
                    if (drain == 0) begin
                        next_st = S_NEXT;
                    end else begin
                        next_drain = drain - 1;
                    end
                end

                S_NEXT: begin
                    if (tk + 1 < KT) begin
                        next_tk = tk + 1;
                        next_st = S_LOAD_W;
                    end else begin
                        next_tk = 0;
                        if (tc + 1 < NT) begin
                            next_tc = tc + 1;
                            next_st = S_LOAD_W;
                        end else begin
                            next_tc = 0;
                            if (tr + 1 < NT) begin
                                next_tr = tr + 1;
                                next_st = S_LOAD_W;
                            end else begin
                                next_st = S_DONE;
                            end
                        end
                    end
                end

                S_DONE: begin
                    next_done = 1'b1;
                    next_st = S_DONE;
                end

                default: begin
                    next_st = S_IDLE;
                end
            endcase

            // commit next-state values (nonblocking)
            st <= next_st;
            tr <= next_tr;
            tc <= next_tc;
            tk <= next_tk;
            t  <= next_t;
            drain <= next_drain;
            load_w <= next_load_w;
            done_led <= next_done;
        end
    end

    // ------------------------------------------------------------------
    // Simulation helper tasks
    // ------------------------------------------------------------------

    // load mem files on demand (simulation-only)
    task automatic load_mem_files(input string a_fn, input string b_fn);
    begin
        $display("[%0t] DUT: load_mem_files A=%s B=%s", $time, a_fn, b_fn);
        $readmemh(a_fn, memA);
        $readmemh(b_fn, memB);
    end
    endtask

    // fast reinit without toggling global reset: zeros memC and clears done_led & FSM state
    // Use this for speed when running many sequential cases
    task automatic reinit();
    begin
        $display("[%0t] DUT: reinit called - clearing memC and internal flags", $time);
        for (int r0=0; r0<N_TOTAL; r0++)
            for (int c0=0; c0<N_TOTAL; c0++)
                memC[c_idx(r0,c0)] = '0;
        // clear controller state - set to IDLE, zero indices (synchronous effect)
        st = S_IDLE;
        tr = 0; tc = 0; tk = 0; t = 0; drain = 0;
        load_w = 0;
        done_led = 0;
        // clear A inputs
        for (int i=0; i<N_PE; i++) begin
            a_left_row[i] = '0;
            a_valid_row[i] = 0;
            a_last_row[i] = 0;
        end
    end
    endtask

    // Write C to file helper (call from TB after done)
    task automatic write_C_to_file(input string fname);
        int fh=$fopen(fname,"w");
        if (fh == 0) begin
            $display("ERROR: cannot open %s", fname);
            return;
        end
        for(int r=0;r<N_TOTAL;r++) begin
            for (int c=0;c<N_TOTAL;c++) begin
                $fwrite(fh,"%0d",memC[c_idx(r,c)]);
                if (c+1<N_TOTAL) $fwrite(fh," ");
            end
            $fwrite(fh,"\n");
        end
        $fclose(fh);
    endtask

endmodule
