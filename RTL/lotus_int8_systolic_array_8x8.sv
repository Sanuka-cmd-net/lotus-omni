`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:       Lotus Omni (Fabless AI Semiconductor)
// Engineer:      Sanuka Nethmira Amarasekara
// Module Name:   lotus_int8_systolic_array_8x8
// Description:   8x8 Systolic Array for INT8 Matrix Multiplication
//
// FIX: Corrected PE port mapping to match the actual lotus_tensor_pe module
//////////////////////////////////////////////////////////////////////////////////

module lotus_int8_systolic_array_8x8 (
    input  logic clk,
    input  logic rst_n,
    input  logic enable,
    input  logic clear_acc,
    input  logic signed [7:0] a_in [0:7],
    input  logic signed [7:0] b_in [0:7],
    output logic signed [31:0] pe_results [0:7][0:7]
);

    // Internal pipelining registers for systolic data flow
    logic signed [7:0]  a_reg [0:7][0:7];
    logic signed [7:0]  b_reg [0:7][0:7];
    logic signed [31:0] p_out [0:7][0:7];

    // Generate 8x8 PE Array
    genvar row, col;
    generate
        for (row = 0; row < 8; row++) begin : gen_row
            for (col = 0; col < 8; col++) begin : gen_col
                
                // Processing Element Instantiation (Fixed Port Mapping)
                lotus_tensor_pe u_pe (
                    .clk(clk),
                    .rst_n(rst_n),
                    .enable(enable),
                    .clear_acc(clear_acc),
                    .in_a(a_reg[row][col]),         // Matches logic signed [7:0] in_a
                    .in_b(b_reg[row][col]),         // Matches logic signed [7:0] in_b
                    .in_acc(32'sd0),                // Assuming partial sums aren't passed vertically in this simple version, or connect properly if needed
                    .sparsity_en(1'b0),             // Connect to sparsity logic if needed, 0 for now
                    .out_a(),                       // Ignored here, handled by a_reg shifting
                    .out_b(),                       // Ignored here, handled by b_reg shifting
                    .out_acc(p_out[row][col])       // Matches logic signed [31:0] out_acc
                );

                // Output assignment
                assign pe_results[row][col] = p_out[row][col];

                // Systolic Data Flow Logic (Pipeline registers)
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        if (col < 7) a_reg[row][col+1] <= 8'sd0;
                        if (row < 7) b_reg[row+1][col] <= 8'sd0;
                    end else if (enable) begin
                        // Pass 'A' horizontally
                        if (col < 7) a_reg[row][col+1] <= a_reg[row][col];
                        // Pass 'B' vertically
                        if (row < 7) b_reg[row+1][col] <= b_reg[row][col];
                    end
                end
            end
        end
    endgenerate

    // Input assignments to the edges of the array
    always_comb begin
        for (int i = 0; i < 8; i++) begin
            a_reg[i][0] = a_in[i];  // Feed A into the left edge
            b_reg[0][i] = b_in[i];  // Feed B into the top edge
        end
    end

endmodule   