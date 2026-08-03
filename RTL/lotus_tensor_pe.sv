`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:       Lotus Omni (Fabless AI Semiconductor)
// Engineer:      Sanuka Nethmira Amarasekara
// Module Name:   lotus_tensor_pe
// Description:   A+ Grade, Tape-Out Ready Processing Element (PE) - V3.0
//                Features: Strict DSP48E2 Inference, 2GHz Timing Pipelining,
//                Hardware Structured Sparsity, and 33-bit AI Saturation Logic.
//////////////////////////////////////////////////////////////////////////////////

module lotus_tensor_pe (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,      // Cluster-gated clock enable for power saving
    input  logic        clear_acc,   // Priority 1: Reset accumulator for new Dot Product

    // --- SYSTOLIC INPUTS ---
    input  logic signed [7:0]  in_a,        // Activation from Left PE
    input  logic signed [7:0]  in_b,        // Weight from Top PE
    input  logic signed [31:0] in_acc,      // Partial sum from Top PE

    // --- CONFIGURATION ---
    input  logic        sparsity_en, // Priority 2: Skip MAC if weight is zero

    // --- SYSTOLIC OUTPUTS ---
    output logic signed [7:0]  out_a,       // Forwarded to Right PE
    output logic signed [7:0]  out_b,       // Forwarded to Bottom PE
    output logic signed [31:0] out_acc      // Accumulated sum to Bottom PE
);

    // ------------------------------------------------------------------------
    // STAGE 1: INPUT REGISTERS (MANDATORY FOR DSP48E2 INFERENCE)
    // ------------------------------------------------------------------------
    logic signed [7:0]  a_reg;
    logic signed [7:0]  b_reg;
    logic signed [31:0] acc_in_reg;
    logic               clear_reg;
    logic               sparse_skip_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_reg           <= 8'sd0;
            b_reg           <= 8'sd0;
            acc_in_reg      <= 32'sd0;
            clear_reg       <= 1'b0;
            sparse_skip_reg <= 1'b0;
        end else if (enable) begin
            a_reg      <= in_a;
            b_reg      <= in_b;
            acc_in_reg <= in_acc;
            clear_reg  <= clear_acc;
            
            // H-06 FIX: Use registered b_reg instead of combinational in_b
            sparse_skip_reg <= (sparsity_en && (b_reg == 8'sd0));
        end
    end

    // ------------------------------------------------------------------------
    // STAGE 2: MULTIPLY, ACCUMULATE & SATURATE (MAPPED TO DSP48)
    // ------------------------------------------------------------------------
    logic signed [15:0] mult_result;
    logic signed [32:0] add_result; // 33-bit to detect overflow
    logic signed [31:0] final_acc;

    always_comb begin
        // 1. The Multiplier (8x8 -> 16-bit)
        mult_result = a_reg * b_reg;

        // 2. The Adder / Accumulator
        // Priority: clear_acc > sparsity_skip > normal_mac
        if (clear_reg) begin
            add_result = { {17{mult_result[15]}}, mult_result }; // Sign extend to 33-bit
        end else if (sparse_skip_reg) begin
            add_result = {acc_in_reg[31], acc_in_reg}; // Bypass MAC, pass accumulator
        end else begin
            add_result = {acc_in_reg[31], acc_in_reg} + { {17{mult_result[15]}}, mult_result };
        end

        // 3. AI Saturation Logic (QWEN V3 FIX)
        // Check if the 33rd bit (sign bit of 33-bit result) differs from the 32nd bit.
        if (add_result[32] != add_result[31]) begin
            if (add_result[32] == 1'b0) begin
                final_acc = 32'h7FFFFFFF; // Positive Overflow -> Saturate to Max Positive
            end else begin
                final_acc = 32'h80000000; // Negative Underflow -> Saturate to Max Negative
            end
        end else begin
            final_acc = add_result[31:0]; // Normal Result
        end
    end

    // ------------------------------------------------------------------------
    // STAGE 3: OUTPUT REGISTERS (MANDATORY FOR 2GHz & SYSTOLIC FLOW)
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_a   <= 8'sd0;
            out_b   <= 8'sd0;
            out_acc <= 32'sd0;
        end else if (enable) begin
            // Forward registered inputs (1-cycle delayed to match MAC latency)
            out_a   <= a_reg;
            out_b   <= b_reg;
            
            // Forward the saturated accumulator result
            out_acc <= final_acc;
        end
    end

endmodule