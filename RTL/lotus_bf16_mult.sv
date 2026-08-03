`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:       Lotus Omni (Fabless AI Semiconductor)
// Engineer:      Sanuka Nethmira Amarasekara
// Module Name:   lotus_bf16_mult - V4.0 ASIC TAPE-OUT READY
//
//
// BFloat16 Format: [15:12]=sign+exponent high, [11:7]=exponent low, [6:0]=mantissa
// Full format: [15]=sign, [14:7]=8-bit exponent (bias=127), [6:0]=7-bit mantissa
// Implicit leading 1: actual mantissa = 1.mmmmmmm (8 bits with hidden bit)
//////////////////////////////////////////////////////////////////////////////////

module lotus_bf16_mult (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,
    
    input  logic [15:0] a_in,
    input  logic [15:0] b_in,
    
    output logic [15:0] result_out
);

    // =========================================================================
    // 1. EXTRACT BF16 FIELDS
    // =========================================================================
    logic sign_a, sign_b;
    logic [7:0] exp_a, exp_b;
    logic [6:0] mant_a, mant_b;
    
    assign sign_a = a_in[15];
    assign exp_a  = a_in[14:7];
    assign mant_a = a_in[6:0];
    
    assign sign_b = b_in[15];
    assign exp_b  = b_in[14:7];
    assign mant_b = b_in[6:0];

    // =========================================================================
    // 2. PIPELINE STAGE 1: SETUP & SPECIAL CASE DETECTION
    // =========================================================================
    logic [7:0] op_a_mant_reg, op_b_mant_reg;
    logic [7:0] exp_sum_reg; 
    logic       sign_res_reg;
    logic       is_zero_reg;
    logic       exp_overflow_reg;
    logic       exp_underflow_reg;

    // Use 10-bit signed logic to safely catch >255 or <0 without overflow
    logic signed [9:0] exp_calc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_a_mant_reg     <= '0;
            op_b_mant_reg     <= '0;
            exp_sum_reg       <= '0;
            sign_res_reg      <= 1'b0;
            is_zero_reg       <= 1'b0;
            exp_overflow_reg  <= 1'b0;
            exp_underflow_reg <= 1'b0;
        end else if (enable) begin
            // Check for zero inputs (exponent = 0 means zero or denorm, flush to zero)
            if (exp_a == 8'h0 || exp_b == 8'h0) begin
                is_zero_reg       <= 1'b1;
                exp_overflow_reg  <= 1'b0;
                exp_underflow_reg <= 1'b0;
            end else begin
                is_zero_reg   <= 1'b0;
                
                // Add implicit leading 1 to mantissa: 1.mmmmmmm → 8 bits
                op_a_mant_reg <= {1'b1, mant_a}; 
                op_b_mant_reg <= {1'b1, mant_b}; 
                
                // Result sign: XOR of input signs
                sign_res_reg  <= sign_a ^ sign_b;

                // Exponent calculation: exp_result = exp_a + exp_b - bias
                // BF16 bias = 127, so: exp_result = exp_a + exp_b - 127
                exp_calc = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd127;
                
                if (exp_calc >= 10'sd255) begin
                    // Exponent overflow → result is Infinity
                    exp_overflow_reg  <= 1'b1;
                    exp_underflow_reg <= 1'b0;
                    exp_sum_reg       <= 8'hFF;  // Max exponent
                end else if (exp_calc <= 10'sd0) begin
                    // Exponent underflow → flush to zero (no denorm support)
                    exp_overflow_reg  <= 1'b0;
                    exp_underflow_reg <= 1'b1;
                    exp_sum_reg       <= 8'h00;
                    is_zero_reg       <= 1'b1;
                end else begin
                    // Normal exponent
                    exp_overflow_reg  <= 1'b0;
                    exp_underflow_reg <= 1'b0;
                    exp_sum_reg       <= exp_calc[7:0];
                end
            end
        end
    end

    // =========================================================================
    // 3. PIPELINE STAGE 2: THE MULTIPLIER (ASIC-OPTIMIZED)
    // =========================================================================
    // FIX ASIC-DSP-001: Removed FPGA-specific optimizations
    //
    // OLD (FPGA only):
    //   wire signed [17:0] dsp_a = {10'b0, op_a_mant_reg};  // 10-bit padding!
    //   wire signed [17:0] dsp_b = {10'b0, op_b_mant_reg};  // 10-bit padding!
    //   (* mult_style = "dsp", use_dsp = "yes" *) logic signed [47:0] dsp_p_reg;
    //
    // NEW (ASIC portable):
    //   Direct 8x8 multiply → 16-bit result
    //   No padding, no DSP-specific attributes
    //   Synopsys/Cadence will automatically choose:
    //   - Wallace tree multiplier (fastest, good area)
    //   - Booth encoded multiplier (balanced)
    //   - Array multiplier (smallest, slower)
    // =========================================================================
    
    logic [15:0] mant_product_reg;
    
    logic [7:0]  exp_res_reg;
    logic        sign_final_reg;
    logic        zero_final_reg;
    logic        ovf_final_reg;
    logic        udf_final_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mant_product_reg <= '0;
            exp_res_reg      <= '0;
            sign_final_reg   <= 1'b0;
            zero_final_reg   <= 1'b0;
            ovf_final_reg    <= 1'b0;
            udf_final_reg    <= 1'b0;
        end else if (enable) begin
            // Direct 8x8 unsigned multiply
            // {1, mant_a} × {1, mant_b} where mant is 7 bits
            // Result range: 1.0 × 1.0 = 1.0  to  ~2.0 × ~2.0 ≈ 4.0
            // Binary: 01.xxxxxxx_xxxxxxxx to 11.xxxxxxx_xxxxxxxx
            mant_product_reg <= op_a_mant_reg * op_b_mant_reg;
            
            // Pipeline other control signals
            exp_res_reg      <= exp_sum_reg;
            sign_final_reg   <= sign_res_reg;
            zero_final_reg   <= is_zero_reg;
            ovf_final_reg    <= exp_overflow_reg;
            udf_final_reg    <= exp_underflow_reg;
        end
    end

    // =========================================================================
    // 4. PIPELINE STAGE 3: NORMALIZE & PACK OUTPUT
    // =========================================================================
    // For 8×8 multiply of {1, mant[6:0]}:
    //   - Result is 16 bits
    //   - Range: [01.0000000_00000000] to [11.1111110_00000001]
    //   - If bit[15]=0: Normal case, leading 1 at bit[14]
    //     → Mantissa = bits[13:7], exponent unchanged
    //   - If bit[15]=1: Overflow case (product >= 2.0)
    //     → Mantissa = bits[14:8], exponent += 1
    // =========================================================================
    
    logic [15:0] final_bf16;
    
    always_comb begin
        if (zero_final_reg || udf_final_reg) begin
            // Zero or underflow → flush to positive/negative zero
            final_bf16 = {sign_final_reg, 15'h0000};
            
        end else if (ovf_final_reg) begin
            // Exponent overflow → Infinity
            final_bf16 = {sign_final_reg, 8'hFF, 7'h00};
            
        end else begin
            // Normal case: normalize the mantissa product
            if (mant_product_reg[15] == 1'b1) begin
                // OVERFLOW CASE: Product >= 2.0
                // Binary form: 1x.yyyyyyy_yyyyyyyy (bit 15 is set)
                // Need to shift right by 1 and increment exponent
                // Mantissa is in bits [14:8]
                final_bf16[15]   = sign_final_reg;
                final_bf16[14:7] = exp_res_reg + 8'h01;  // Increment exponent
                final_bf16[6:0]  = mant_product_reg[14:8]; // Extract 7-bit mantissa
                
            end else begin
                // NORMAL CASE: Product in range [1.0, 2.0)
                // Binary form: 01.yyyyyyy_yyyyyyyy (bit 15 is clear)
                // Leading 1 is at bit 14
                // Mantissa is in bits [13:7]
                final_bf16[15]   = sign_final_reg;
                final_bf16[14:7] = exp_res_reg;
                final_bf16[6:0]  = mant_product_reg[13:7]; // Extract 7-bit mantissa
            end
        end
    end

    assign result_out = final_bf16;

endmodule