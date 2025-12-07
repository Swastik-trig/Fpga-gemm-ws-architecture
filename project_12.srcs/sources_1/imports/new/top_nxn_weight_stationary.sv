`timescale 1ns/1ps
// top_nxn_weight_stationary.sv
// N x N mesh of weight-stationary PEs.
// Assumes each PE registers a_out (data moves right one cycle).
module top_nxn_weight_stationary #(
    parameter int N = 64,
    parameter int K = 64,
    parameter int DATA_W = 16,
    parameter int ACC_W  = 48
)(
    input  logic clk,
    input  logic rst,

    // Load weights: one K-vector per column j, broadcast to all rows in that column
    input  logic                     load_w,                     // pulse to (re)load weights
    input  logic signed [DATA_W-1:0] B_col [0:N-1][0:K-1],       // B[k][j] per column j

    // Stream A: one value per row per cycle (A[i][k] for same k across all columns)
    input  logic signed [DATA_W-1:0] a_left_row [0:N-1],         // enters at col 0
    input  logic                     a_valid_row  [0:N-1],
    input  logic                     a_last_row   [0:N-1],       // k==K-1 pulse per row

    // Outputs
    output logic signed [ACC_W-1:0]  emit [0:N-1][0:N-1],        // C[i][j]
    output logic                     ev   [0:N-1][0:N-1]
);

    // pipeline arrays (a flows right via PE registered a_out, valid/last are registered here)
    logic signed [DATA_W-1:0] a_pipe   [0:N-1][0:N-1]; // a_pipe[i][j] holds PE(i,j).a_out
    logic                     v_pipe   [0:N-1][0:N-1];
    logic                     last_pipe[0:N-1][0:N-1];

    genvar i, j;
    generate
        for (i = 0; i < N; i++) begin : ROW
            for (j = 0; j < N; j++) begin : COL
                // inputs to this PE come from either leftmost inputs or previous column's a_pipe
                wire signed [DATA_W-1:0] a_in_wire = (j == 0) ? a_left_row[i] : a_pipe[i][j-1];
                wire                     v_in_wire = (j == 0) ? a_valid_row[i] : v_pipe[i][j-1];
                wire                     l_in_wire = (j == 0) ? a_last_row[i]  : last_pipe[i][j-1];

                // Instantiate PE - note w_in is the column vector B_col[j]
                pe_ws_generic #(.DATA_W(DATA_W), .ACC_W(ACC_W), .K(K)) pe_inst (
                    .clk(clk), .rst(rst),
                    .load_w(load_w),
                    .w_in(B_col[j]),

                    .a_in(a_in_wire),
                    .a_valid(v_in_wire),
                    .a_last(l_in_wire),

                    .a_out(a_pipe[i][j]),     // registered inside PE
                    .emit_value(emit[i][j]),
                    .emit_valid(ev[i][j])
                );

                // register valid/last signals so they travel right in-step with registered a_out
                always_ff @(posedge clk or posedge rst) begin
                    if (rst) begin
                        v_pipe[i][j]    <= 1'b0;
                        last_pipe[i][j] <= 1'b0;
                    end else begin
                        v_pipe[i][j]    <= v_in_wire;
                        last_pipe[i][j] <= l_in_wire;
                    end
                end
            end
        end
    endgenerate

endmodule
