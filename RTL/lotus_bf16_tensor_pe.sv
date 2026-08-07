`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// Module: lotus_bf16_tensor_pe - V10.0 OUTER-PRODUCT LOCAL ACCUMULATOR
//
// FIX V10.0 (THIS VERSION): DATAFLOW ALIGNMENT FIX
//   Bug: V9.5 used a VERTICAL systolic accumulator (in_acc from the PE above).
//        array_enable was only high during the 8 S_FEED cycles and the
//        wavefront had no input skewing, so the vertical accumulation never
//        completed - only 2 of 64 results were non-zero.
//   Fix: Each PE now holds a LOCAL accumulator. Over the feed cycles the PE
//        accumulates a_in[k] * b_in[k]. clear_acc is pipelined WITH the data
//        so it aligns with the FIRST product (k=0):
//            Stage 1: sample a_in, b_in, clear_acc
//            Stage 2: mult_result_reg, clear_pipe_reg
//            Stage 3: acc <= clear_pipe ? mult : saturate(acc + mult)
//        The `in_acc` port is retained for interface compatibility but UNUSED.
//
// PRESERVED from V9.5:
//   - Synchronous reset (DSP48 SR packing - no async reset)
//   - Registered multiply for DSP48 MREG inference
//   - Operand isolation / power gating on zero inputs
//   - 37-bit accumulate + INT32 saturation
////////////////////////////////////////////////////////////////////////////////

(* use_dsp = "yes" *)
module lotus_bf16_tensor_pe (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,
    input  logic        clear_acc,
    input  logic signed [15:0] a_in,
    input  logic signed [15:0] b_in,
    input  logic signed [31:0] in_acc,   // V10.0: UNUSED (kept for compatibility)
    output logic signed [15:0] a_out,
    output logic signed [15:0] b_out,
    output logic signed [31:0] out_acc
);

    // =========================================================================
    // 1. OPERAND ISOLATION (POWER SAVING)
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
    // 2. PIPELINE STAGE 1: INPUT REGISTERS + clear_acc ALIGNMENT
    //    clear_reg travels WITH the k=0 data through the pipeline.
    // =========================================================================
    logic signed [17:0] a_reg;
    logic signed [17:0] b_reg;
    logic               clear_reg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            a_reg     <= 18'sd0;
            b_reg     <= 18'sd0;
            clear_reg <= 1'b0;
        end else if (enable) begin
            a_reg     <= $signed({{2{a_gated[15]}}, a_gated});
            b_reg     <= $signed({{2{b_gated[15]}}, b_gated});
            clear_reg <= clear_acc;      // sampled with the k=0 inputs
        end
    end

    // =========================================================================
    // 3. PIPELINE STAGE 2: MULTIPLY REGISTER (DSP48 MREG)
    // =========================================================================
    (* use_dsp = "yes" *) logic signed [35:0] mult_result_reg;
    logic               clear_pipe_reg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mult_result_reg <= 36'sd0;
            clear_pipe_reg  <= 1'b0;
        end else if (enable) begin
            mult_result_reg <= a_reg * b_reg;
            clear_pipe_reg  <= clear_reg;   // aligned with mult_result_reg
        end
    end

    // =========================================================================
    // 4. PIPELINE STAGE 3: LOCAL ACCUMULATE + SATURATE + OUTPUT
    //    acc_reg feeds back into the adder (LOCAL MAC, no vertical chain).
    // =========================================================================
    localparam signed [31:0] MAX_POS = 32'h7FFFFFFF;
    localparam signed [31:0] MAX_NEG = 32'h80000000;

    logic signed [31:0] acc_reg;          // LOCAL accumulator (feedback)
    logic signed [36:0] mac_temp;         // 37-bit sum
    logic signed [31:0] mac_saturated;

    always_comb begin
        if (clear_pipe_reg) begin
            // k=0 product: RESTART accumulation with this product
            mac_temp = $signed(mult_result_reg);
        end else begin
            // k>0: accumulate into the LOCAL accumulator
            mac_temp = $signed({acc_reg[31], acc_reg}) +
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

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc_reg <= 32'sd0;
            a_out   <= 16'sd0;
            b_out   <= 16'sd0;
        end else if (enable) begin
            acc_reg <= mac_saturated;    // local feedback accumulate
            a_out   <= a_in;
            b_out   <= b_in;
        end
    end

    assign out_acc = acc_reg;

endmodule