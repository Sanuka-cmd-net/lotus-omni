`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// Company:       Lotus Omni (Fabless AI Semiconductor)
// Engineer:      Sanuka Nethmira Amarasekara
// Module Name:   lotus_int8_systolic_array_8x8 - V2.0 OUTER-PRODUCT BROADCAST
//
// FIX V2.0: Converted from wavefront to OUTER-PRODUCT BROADCAST (matches BF16 V5.1).
//   - a_in_reg[i] broadcast to all PEs in row i, b_in_reg[j] to column j
//   - clear_acc REGISTERED (clear_acc_reg) to align with data path
//   - in_acc fed back from out_acc (lotus_tensor_pe uses in_acc pass-through,
//     so feedback makes it a local accumulator)
//   - No wavefront a_reg/b_reg shifting
////////////////////////////////////////////////////////////////////////////////

module lotus_int8_systolic_array_8x8 (
    input  logic clk,
    input  logic rst_n,
    input  logic enable,
    input  logic clear_acc,
    input  logic signed [7:0] a_in [0:7],
    input  logic signed [7:0] b_in [0:7],
    output logic signed [31:0] pe_results [0:7][0:7]
);

    // =========================================================================
    // INPUT REGISTERS + clear_acc REGISTERED (aligned with data path)
    // =========================================================================
    logic signed [7:0] a_in_reg [0:7];
    logic signed [7:0] b_in_reg [0:7];
    logic              clear_acc_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int k = 0; k < 8; k++) begin
                a_in_reg[k] <= 8'sd0;
                b_in_reg[k] <= 8'sd0;
            end
            clear_acc_reg <= 1'b0;
        end else if (enable) begin
            for (int k = 0; k < 8; k++) begin
                a_in_reg[k] <= a_in[k];
                b_in_reg[k] <= b_in[k];
            end
            clear_acc_reg <= clear_acc;
        end
    end

    // =========================================================================
    // PE OUTPUT / FEEDBACK WIRES
    //   acc_wire[i][j] carries out_acc BACK into in_acc (local accumulation)
    // =========================================================================
    logic signed [31:0] acc_wire [0:7][0:7];

    // =========================================================================
    // PE GRID - 8x8 OUTER-PRODUCT ACCUMULATION
    // =========================================================================
    genvar i, j;
    generate
        for (i = 0; i < 8; i++) begin : row_gen
            for (j = 0; j < 8; j++) begin : col_gen
                lotus_tensor_pe u_pe (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .enable    (enable),
                    .clear_acc (clear_acc_reg),
                    .sparsity_en(1'b0),
                    .in_a      (a_in_reg[i]),
                    .in_b      (b_in_reg[j]),
                    .in_acc    (acc_wire[i][j]),   // feedback: out_acc -> in_acc
                    .out_a     (),
                    .out_b     (),
                    .out_acc   (acc_wire[i][j])
                );
                assign pe_results[i][j] = acc_wire[i][j];
            end
        end
    endgenerate

endmodule