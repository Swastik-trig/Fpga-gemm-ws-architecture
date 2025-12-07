`timescale 1ns/1ps
module pe_ws_generic #(
    parameter int DATA_W = 16,
    parameter int ACC_W  = 32,
    parameter int K      = 16
)(
    input  logic clk,
    input  logic rst,

    // Load weights (B[k][j]) into this PE (pulse load=1 for one cycle)
    input  logic                     load_w,
    input  logic signed [DATA_W-1:0] w_in [0:K-1],

    // Stream A across the row (left -> right)
    input  logic signed [DATA_W-1:0] a_in,
    input  logic                     a_valid,
    input  logic                     a_last,   // high when k == K-1 for this dot product
    output logic signed [DATA_W-1:0] a_out,    // pass to next PE on the right

    // Output C_ij
    output logic signed [ACC_W-1:0]  emit_value,
    output logic                     emit_valid
);

    // safe phase width (handle K==1)
    localparam int PH_BITS = (K > 1) ? $clog2(K) : 1;
    logic [PH_BITS-1:0] phase_r, next_phase;

    // Local weights
    logic signed [DATA_W-1:0] w [0:K-1];

    // accumulator (registered) and next value
    logic signed [ACC_W-1:0] acc_r, next_acc;

    // product computed from registered phase's weight
    logic signed [ACC_W-1:0] product;
    logic signed [DATA_W-1:0] w_phase;

    // pick weight for current phase (registered)
    assign w_phase = w[phase_r];

    // register a_out so data and v_pipe/last_pipe align
    always_ff @(posedge clk or posedge rst) begin
        if (rst) a_out <= '0;
        else     a_out <= a_in;
    end

    // combinational next-state calculations
    always_comb begin
        product = '0;
        next_acc = acc_r;
        next_phase = phase_r;

        if (a_valid) begin
            // multiply signed (product width must fit in ACC_W)
            product = $signed(a_in) * $signed(w_phase);
            next_acc = acc_r + product;

            if (a_last) begin
                // after emitting we will clear for next dot
                next_phase = '0;
            end else begin
                // advance phase (wrap)
                next_phase = (phase_r == K-1) ? '0 : (phase_r + 1);
            end
        end
    end

    // sequential: registers, load weights, emit on last
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int kidx=0; kidx<K; kidx++) w[kidx] <= '0;
            phase_r <= '0;
            acc_r <= '0;
            emit_valid <= 1'b0;
            emit_value <= '0;
        end else begin
            // default outputs
            emit_valid <= 1'b0;
            emit_value <= '0;

            if (load_w) begin
                for (int kidx=0; kidx<K; kidx++) w[kidx] <= w_in[kidx];
                acc_r   <= '0;
                phase_r <= '0;
            end else if (a_valid) begin
                // commit accumulator and phase
                acc_r <= next_acc;
                phase_r <= next_phase;

                if (a_last) begin
                    // emit the accumulated value (next_acc already computed)
                    emit_value <= next_acc;
                    emit_valid <= 1'b1;
                    // clear acc ready for next dot product
                    acc_r <= '0;
                    phase_r <= '0;
                end
            end
        end
    end

endmodule
