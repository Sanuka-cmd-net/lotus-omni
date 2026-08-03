`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// Module: lotus_bf16_tensor_pe - V9.5 SYNC RESET FOR DSP48 INFERENCE
//
// FIX V9.5 (THIS VERSION):
//   Bug #11 (ASYNC RESET DSP BLOCKING): V9.4 used `posedge clk or negedge rst_n`.
//     Xilinx DSP48E1 primitives only support Synchronous Resets (SR). An async
//     reset forces Vivado to implement the reset using external LUTs, preventing
//     DSP packing (Synth 8-5844) and ruining timing.
//     Fix: Changed all always_ff blocks to Synchronous Reset 
//     (`posedge clk`). DSP48E1s will now pack perfectly, saving LUTs and 
//     drastically improving timing.
//
// PRESERVED from V9.4:
//   - Registered multiply for DSP48 MREG inference
//   - Operand isolation / power gating on zero inputs (sparsity)
//   - Saturation logic (clip to INT32 MAX_POS / MAX_NEG)
////////////////////////////////////////////////////////////////////////////////

(* use_dsp = "yes" *)
module lotus_bf16_tensor_pe (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,
    input  logic        clear_acc,
    input  logic signed [15:0] a_in,
    input  logic signed [15:0] b_in,
    input  logic signed [31:0] in_acc,
    output logic signed [15:0] a_out,
    output logic signed [15:0] b_out,
    output logic signed [31:0] out_acc
);

    // =========================================================================
    // 1. OPERAND ISOLATION (POWER SAVING LOGIC)
    // =========================================================================
    logic is_zero_op;
    logic signed [15:0] a_gated;
    logic signed [15:0] b_gated;

    always_comb begin
        is_zero_op = (a_in == 16'sd0) || (b_in == 16'sd0);
        a_gated    = is_zero_op ? 16'sd0 : a_in;
        b_gated    = is_zero_op ? 16'sd0 : b_in;
    end

    // =========================================================================
    // 2. PIPELINE STAGE 1: INPUT REGISTERS (AREG, BREG, CREG equivalents)
    // =========================================================================
    logic signed [17:0] a_reg;
    logic signed [17:0] b_reg;
    logic signed [31:0] acc_reg;
    logic               clear_reg;

    // FIX V9.5: Removed `or negedge rst_n` for Synchronous Reset
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            a_reg     <= 18'sd0;
            b_reg     <= 18'sd0;
            acc_reg   <= 32'sd0;
            clear_reg <= 1'b0;
        end else if (enable) begin
            a_reg     <= $signed({{2{a_gated[15]}}, a_gated});
            b_reg     <= $signed({{2{b_gated[15]}}, b_gated});
            acc_reg   <= $signed(in_acc);
            clear_reg <= clear_acc;
        end
    end

    // =========================================================================
    // 3. PIPELINE STAGE 2: MULTIPLY REGISTER (MREG equivalent)
    // =========================================================================
    (* use_dsp = "yes" *) logic signed [35:0] mult_result_reg;
    logic signed [31:0] acc_pipe_reg;
    logic               clear_pipe_reg;

    // FIX V9.5: Removed `or negedge rst_n` for Synchronous Reset
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mult_result_reg <= 36'sd0;
            acc_pipe_reg    <= 32'sd0;
            clear_pipe_reg  <= 1'b0;
        end else if (enable) begin
            mult_result_reg <= a_reg * b_reg;
            acc_pipe_reg    <= acc_reg;
            clear_pipe_reg  <= clear_reg;
        end
    end

    // =========================================================================
    // 4. PIPELINE STAGE 3: ACCUMULATE, SATURATE & OUTPUT (PREG equivalent)
    // =========================================================================
    localparam signed [31:0] MAX_POS = 32'h7FFFFFFF;
    localparam signed [31:0] MAX_NEG = 32'h80000000;

    logic signed [36:0] mac_temp;      
    logic signed [31:0] mac_saturated;

    always_comb begin
        if (clear_pipe_reg) begin
            mac_temp = $signed(mult_result_reg);
        end else begin
            mac_temp = $signed({acc_pipe_reg[31], acc_pipe_reg}) +
                       $signed(mult_result_reg);
        end

        if (mac_temp > $signed({5'h0, MAX_POS})) begin
            mac_saturated = MAX_POS;   
        end else if (mac_temp < $signed({5'h1F, MAX_NEG})) begin
            mac_saturated = MAX_NEG;   
        end else begin
            mac_saturated = mac_temp[31:0];  
        end
    end

    // FIX V9.5: Removed `or negedge rst_n` for Synchronous Reset
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            out_acc <= 32'sd0;
            a_out   <= 16'd0;
            b_out   <= 16'd0;
        end else if (enable) begin
            out_acc <= mac_saturated;  
            a_out   <= a_in;
            b_out   <= b_in;
        end
    end

endmodule