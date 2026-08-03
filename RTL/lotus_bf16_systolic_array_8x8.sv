// =========================================
// File Name: lotus_bf16_systolic_array_8x8.sv
// =========================================

`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// Company:       Lotus Omni (Fabless AI Semiconductor)
// Engineer:      Sanuka Nethmira Amarasekara
// Module Name:   lotus_bf16_systolic_array_8x8 - V4.2 GENVAR FIX
//
// V4.2 CRITICAL FIX (vs V4.1):
//
// FIX SA-013: Mixed genvar/int loop variables caused Vivado 2025.2
//             elaboration error. Both loops in the same generate
//             block must use 'genvar'.
//
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
    // INTERNAL WIRES (module scope)
    // =========================================================================
    logic [15:0] a_wire [0:7][0:8];
    logic [15:0] b_wire [0:8][0:7];
    logic [31:0] acc_wire [0:7][0:7];
    logic [31:0] acc_in_wire [0:7][0:7];
    logic pe_enable;

    assign pe_enable = enable;

    // =========================================================================
    // INPUT REGISTERS
    // =========================================================================
    logic [15:0] a_in_reg [0:7];
    logic [15:0] b_in_reg [0:7];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int k = 0; k < 8; k++) begin
                a_in_reg[k] <= 16'd0;
                b_in_reg[k] <= 16'd0;
            end
        end else if (enable) begin
            for (int k = 0; k < 8; k++) begin
                a_in_reg[k] <= a_in[k];
                b_in_reg[k] <= b_in[k];
            end
        end
    end

    // =========================================================================
    // INPUT MAPPING
    // =========================================================================
    genvar ii;
    generate
        for (ii = 0; ii < 8; ii++) begin : map_inputs
            assign a_wire[ii][0] = a_in_reg[ii];
            assign b_wire[0][ii] = b_in_reg[ii];
        end
    endgenerate

    // =========================================================================
    // ACCUMULATOR MUX (PE-013: use genvar for BOTH loops)
    // =========================================================================
    genvar im, jm;
    generate
        for (im = 0; im < 8; im++) begin : acc_mux_row
            for (jm = 0; jm < 8; jm++) begin : acc_mux_col
                assign acc_in_wire[im][jm] = (im == 0) ? 32'h0 : acc_wire[im-1][jm];
            end
        end
    endgenerate

    // =========================================================================
    // PE GRID - 8x8 systolic array
    // =========================================================================
    genvar i, j;
    generate
        for (i = 0; i < 8; i++) begin : row_gen
            for (j = 0; j < 8; j++) begin : col_gen
                lotus_bf16_tensor_pe u_pe (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .enable    (pe_enable),
                    .clear_acc (clear_acc),
                    .a_in      (a_wire[i][j]),
                    .b_in      (b_wire[i][j]),
                    .in_acc    (acc_in_wire[i][j]),
                    .a_out     (a_wire[i][j+1]),
                    .b_out     (b_wire[i+1][j]),
                    .out_acc   (acc_wire[i][j])
                );
                assign pe_results[i][j] = acc_wire[i][j];
            end
        end
    endgenerate

endmodule
