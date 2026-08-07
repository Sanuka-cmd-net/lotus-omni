// =========================================
// File Name: lotus_bf16_systolic_array_8x8.sv
// =========================================

`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// Company:       Lotus Omni (Fabless AI Semiconductor)
// Engineer:      Sanuka Nethmira Amarasekara
// Module Name:   lotus_bf16_systolic_array_8x8 - V5.1 CLEAR-ACC ALIGNMENT FIX
//
// FIX V5.1 (THIS VERSION): CLEAR_ACC PIPELINE ALIGNMENT
//   Bug in V5.0: clear_acc was fed COMBINATIONALLY to the PEs, but a_in/b_in
//        go through the a_in_reg/b_in_reg input-register stage. So clear_acc
//        arrived at the PE adder ONE CYCLE EARLY relative to the first product.
//        Result: first product dropped / partial sums wiped → only some results
//        non-zero (0x4, 0x6) instead of all 64 = 0x30.
//
//   Fix: Register clear_acc alongside a_in_reg/b_in_reg (clear_acc_reg) so it
//        travels the SAME pipeline depth as the data. Now clear aligns exactly
//        with the first product landing at the PE adder.
//
// PRESERVED from V5.0:
//   - Outer-product broadcast accumulation (a_in_reg[i] row, b_in_reg[j] col)
//   - Each PE accumulates locally, no vertical acc chain
//   - genvar-only generate loops, module interface unchanged
////////////////////////////////////////////////////////////////////////////////

module lotus_bf16_systolic_array_8x8_v3 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,
    input  logic        clear_acc,
    input  logic [15:0] a_in  [0:7],
    input  logic [15:0] b_in  [0:7],
    output logic [31:0] pe_results [0:7][0:7]
);

    // =========================================================================
    // INPUT REGISTERS + V5.1: clear_acc REGISTERED (aligned with data path)
    //   a_in/b_in are registered here (1 stage) before reaching the PE.
    //   clear_acc MUST also be registered here so it reaches the PE adder at
    //   the SAME cycle as the first product. (V5.0 fed it combinationally,
    //   making it arrive 1 cycle early.)
    // =========================================================================
    logic [15:0] a_in_reg [0:7];
    logic [15:0] b_in_reg [0:7];
    logic        clear_acc_reg;      // V5.1 NEW

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int k = 0; k < 8; k++) begin
                a_in_reg[k] <= 16'd0;
                b_in_reg[k] <= 16'd0;
            end
            clear_acc_reg <= 1'b0;
        end else if (enable) begin
            for (int k = 0; k < 8; k++) begin
                a_in_reg[k] <= a_in[k];
                b_in_reg[k] <= b_in[k];
            end
            clear_acc_reg <= clear_acc;   // V5.1: aligned with data
        end
    end

    // =========================================================================
    // PE OUTPUT WIRES
    // =========================================================================
    logic [31:0] acc_wire [0:7][0:7];

    // =========================================================================
    // PE GRID - 8x8 OUTER-PRODUCT ACCUMULATION
    //   PE(i,j).a_in = a_in_reg[i]  (broadcast across row i)
    //   PE(i,j).b_in = b_in_reg[j]  (broadcast down column j)
    //   PE(i,j).clear_acc = clear_acc_reg (V5.1: aligned with data)
    // =========================================================================
    genvar i, j;
    generate
        for (i = 0; i < 8; i++) begin : row_gen
            for (j = 0; j < 8; j++) begin : col_gen
                lotus_bf16_tensor_pe u_pe (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .enable    (enable),
                    .clear_acc (clear_acc_reg),   // V5.1: was clear_acc
                    .a_in      (a_in_reg[i]),
                    .b_in      (b_in_reg[j]),
                    .in_acc    (32'sd0),
                    .a_out     (),
                    .b_out     (),
                    .out_acc   (acc_wire[i][j])
                );
                assign pe_results[i][j] = acc_wire[i][j];
            end
        end
    endgenerate

endmodule