`timescale 1ns/1ps

`include "tb_para.svh" // your parameter defines (TB_N_PE etc). Alternatively change localparams below.

module tb_top_fpga_gemm;

  // ===== Defaults (used if tb_params.svh didn't define overrides) =====
`ifndef TB_N_PE
  localparam int N_PE    = 16;
`else
  localparam int N_PE    = `TB_N_PE;
`endif

`ifndef TB_TILE_K
  localparam int TILE_K  = 16;
`else
  localparam int TILE_K  = `TB_TILE_K;
`endif

`ifndef TB_N_TOTAL
  localparam int N_TOTAL = 128;
`else
  localparam int N_TOTAL = `TB_N_TOTAL;
`endif

`ifndef TB_K_TOTAL
  localparam int K_TOTAL = N_TOTAL;
`else
  localparam int K_TOTAL = `TB_K_TOTAL;
`endif

`ifndef TB_DATA_W
  localparam int DATA_W  = 16;
`else
  localparam int DATA_W  = `TB_DATA_W;
`endif

`ifndef TB_ACC_W
  localparam int ACC_W   = 48;
`else
  localparam int ACC_W   = `TB_ACC_W;
`endif

  // how many cases to run in one simulator invocation
  localparam int NUM_CASES = 1; // change to 1000 when ready (start small)

  // ===== Clk/Reset/Start =====
  logic clk, rst, start, done_led;

  initial clk = 1'b0;
  always #5 clk = ~clk;   // 100 MHz

  // ===== Instantiate DUT =====
  top_fpga_gemm_ws #(
    .N_PE(N_PE), .TILE_K(TILE_K),
    .N_TOTAL(N_TOTAL), .K_TOTAL(K_TOTAL),
    .DATA_W(DATA_W), .ACC_W(ACC_W)
  ) UUT (
    .clk(clk),
    .rst(rst),
    .start(start),
    .done_led(done_led)
  );

  // ===== Golden handling (from c_golden.txt) =====
  function automatic int c_idx(input int r, input int c);
    return r*N_TOTAL + c;
  endfunction

  integer gold_f;
  int gold_vals [0:N_TOTAL*N_TOTAL-1];

  task automatic load_golden(input string fname);
    int v, count; string line;
    begin
      gold_f = $fopen(fname, "r");
      if (gold_f == 0) $fatal(1, "Cannot open %s", fname);

      count = 0;
      while (!$feof(gold_f) && count < N_TOTAL*N_TOTAL) begin
        if ($fscanf(gold_f, "%d", v) == 1) begin
          gold_vals[count] = v;
          count++;
        end else begin
          // consume a bad line
          line = "";
          line = $fgets(line, gold_f);
        end
      end
      $fclose(gold_f);
      if (count != N_TOTAL*N_TOTAL)
        $fatal(1, "Golden count=%0d, expected=%0d (%s)", count, N_TOTAL*N_TOTAL, fname);

      $display("[%0t] Golden loaded: %0d values from %s.", $time, count, fname);
    end
  endtask

  // ===== Compare =====
  task automatic compare_with_golden;
    int mism = 0;
    int r, c, idx;
    int got, exp;
    begin
      UUT.write_C_to_file("c_from_verilog.txt"); // optional snapshot
      $display("[%0t] Wrote c_from_verilog.txt", $time);

      $display("Top-left 8x8 DUT C:");
      for (r = 0; r < 8; r++) begin
        $write("[ ");
        for (c = 0; c < 8; c++) begin
          idx = c_idx(r,c);
          got = UUT.memC[idx]; // assumes memC is visible in UUT for TB (simulation)
          $write("%8d ", got);
        end
        $write("]\n");
      end

      for (r = 0; r < N_TOTAL; r++) begin
        for (c = 0; c < N_TOTAL; c++) begin
          idx = c_idx(r,c);
          got = UUT.memC[idx];
          exp = gold_vals[idx];
          if (got !== exp) begin
            if (mism < 32)
              $display("Mismatch at (%0d,%0d): got=%0d gold=%0d", r, c, got, exp);
            mism++;
          end
        end
      end

      if (mism == 0)
        $display("✅ PASS: %0d/%0d matched.", N_TOTAL*N_TOTAL, N_TOTAL*N_TOTAL);
      else
        $fatal(1, "❌ FAIL: %0d mismatches out of %0d.", mism, N_TOTAL*N_TOTAL);
    end
  endtask

  // ===== TB multi-case stimulus =====
  initial begin
    integer case_id;
    string a_name, b_name, c_name, out_name;

    $display("TB config: N_TOTAL=%0d, K_TOTAL=%0d, N_PE=%0d, TILE_K=%0d, DATA_W=%0d, ACC_W=%0d, NUM_CASES=%0d",
             N_TOTAL, K_TOTAL, N_PE, TILE_K, DATA_W, ACC_W, NUM_CASES);

    // initial reset
    rst   = 1'b1;
    start = 1'b0;
    repeat (20) @(posedge clk);
    rst = 1'b0;
    $display("[%0t] Released reset", $time);

    // loop all cases (generate filenames must exist beforehand)
    for (case_id = 0; case_id < NUM_CASES; case_id++) begin
      a_name = $sformatf("a_flat_%0d.mem", case_id);
      b_name = $sformatf("b_flat_%0d.mem", case_id);
      c_name = $sformatf("c_golden_%0d.txt", case_id);
      out_name = $sformatf("c_from_verilog_%0d.txt", case_id);

      // load A/B into DUT
      $display("[%0t] CASE %0d: Load A=%s B=%s", $time, case_id, a_name, b_name);
      UUT.load_mem_files(a_name, b_name);

      // load golden locally
      load_golden(c_name);

      // small settle
      repeat (2) @(posedge clk);

      // kick off
      @(posedge clk); start = 1'b1;
      @(posedge clk); start = 1'b0;
      $display("[%0t] CASE %0d: started", $time, case_id);

      // wait for compute done (S_DONE sets done_led)
      wait (done_led == 1'b1);
      $display("[%0t] CASE %0d: compute done", $time, case_id);

      // compare & dump
      compare_with_golden();
      UUT.write_C_to_file(out_name);

      // reinit DUT for next case (fast reinit task inside DUT)
      $display("[%0t] CASE %0d: reinitializing DUT for next run", $time, case_id);
      UUT.reinit();

      // small settle after reinit
      repeat (4) @(posedge clk);
    end

    $display("[%0t] All %0d cases completed. Exiting.", $time, NUM_CASES);
    $finish;
  end

  // Provide visibility of memC for TB (simulation-only). If your simulator requires visibility adjust paths.
  // synthesis translate_off
  // nothing else here
  // synthesis translate_on

endmodule
