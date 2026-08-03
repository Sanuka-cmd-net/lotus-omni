`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:       Lotus Omni (Fabless AI Semiconductor)
// Engineer:      Sanuka Nethmira Amarasekara
// Module Name:   lotus_sparsity_engine_v3 - V3.4 OUTPUT HOLD FIX
//
// FIX SPARSE-HS-001: Output registers now hold their values when the downstream
//   consumer is stalled (out_valid=1 but out_ready=0).
//   Previously the output always_ff updated every cycle unconditionally, so
//   when the tensor flow gate deasserted out_ready (backpressure), the output
//   registers could be overwritten by new stg2 data before the consumer had
//   consumed the current beat, silently corrupting the sparse result stream.
//   Fix: the output update is gated by !(out_valid_reg && !out_ready):
//     - out_valid=0               → !(0) = 1  → update (no stall)
//     - out_valid=1, out_ready=1  → !(1&&0)=1 → update (consumed, load next)
//     - out_valid=1, out_ready=0  → !(1&&1)=0 → hold  (stalled, preserve)
//
// CRITICAL FIXES V3.3 (preserved):
//   FIX SYNTH-SPARSE: Loop variable from logic to int
//     - Changed loop variable 'j' from logic [5:0] to int
//     - Prevents latch inference in combinational logic
//   FIX HIGH-005: Backpressure stall - pipeline gating
//   FIX HIGH-009: Output register synchronization
//   FIX CRIT-008: Removed duplicate output drivers
//   FIX NORM-003: Replaced integer with logic for counters
//   FIX NORM-015: Explicit reset for stg1_meta
//   FIX SYNTH-001: Removed 'logic [1:0] tmp;' from inside always_comb
//
// Architecture - 2:4 Structured Sparsity Engine:
//   - Input: 8×8 INT8 weight matrix (dense, 64 bytes)
//   - Stage 1: Scan + identify non-zero pairs (2:4 selection)
//   - Stage 2: Prefix-sum for compressed index generation
//   - Stage 3: Output compressed values + 2-bit metadata per group
//   - Backpressure: valid/ready handshake, pipeline freeze on !ready
//
// 2:4 sparsity: in every group of 4 weights, exactly 2 are non-zero.
// This matches NVIDIA Ampere/Hopper structured sparsity standard.
//////////////////////////////////////////////////////////////////////////////////

module lotus_sparsity_engine_v3 import lotus_pkg::*; (
    input  logic clk,
    input  logic rst_n,

    // --- INPUT (dense 8×8 matrix) ---
    input  logic signed [7:0]  dense_in [0:63],   // 64 INT8 values (row-major)
    input  logic               in_valid,
    output logic               in_ready,

    // --- OUTPUT (compressed 2:4 format) ---
    output logic signed [7:0]  sparse_out [0:31], // 32 non-zero values (50% dense)
    output logic [2:0]         meta_out   [0:15], // 3-bit selector per group of 4
    output logic [5:0]         nz_count_out,      // Non-zero count (0-32)
    output logic               out_valid,
    input  logic               out_ready
);

    // =========================================================================
    // INTERNAL DATA TYPES AND CONSTANTS
    // =========================================================================
    localparam GROUPS = 16;  // 16 groups of 4 elements (64 total)
    localparam PAIRS  = 32;  // 32 pairs of non-zero values (2 per group)

    // =========================================================================
    // LOCAL SIGNALS FOR STAGE 1 COMBINATIONAL LOGIC
    // =========================================================================
    logic signed [7:0] s1_v [0:15][0:3];     // Temporary arrays for group processing
    logic [7:0]        s1_abs_v [0:15][0:3]; // Absolute values for each group
    logic [1:0]        s1_sel0 [0:15];       // Selected index 0 for each group
    logic [1:0]        s1_sel1 [0:15];       // Selected index 1 for each group
    
    // ✅ STEP 1 FIX: Moved from inside always_comb loop to module level
    logic [1:0]        tmp;

    // =========================================================================
    // PIPELINE STAGES
    // =========================================================================
    // Stage 0: Input latch
    logic signed [7:0] stg0_data [0:63];
    logic              stg0_valid;

    // Stage 1: 2:4 Selection
    logic signed [7:0] stg1_sparse [0:31];
    logic [2:0]        stg1_meta   [0:15];
    logic              stg1_valid;
    logic              stall_stg1;

    // Stage 2: Prefix sum + metadata pack
    logic signed [7:0] stg2_sparse [0:31];
    logic [2:0]        stg2_meta   [0:15];
    logic              stg2_valid;
    logic              stall_stg2;

    // =========================================================================
    // BACKPRESSURE LOGIC
    // =========================================================================
    assign stall_stg2 = stg2_valid && !out_ready;
    assign stall_stg1 = stg1_valid && stall_stg2;
    assign in_ready    = !stall_stg1;

    // =========================================================================
    // STAGE 0 → INPUT LATCH
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stg0_valid <= 1'b0;
            for (int i = 0; i < 64; i++) stg0_data[i] <= 8'h0;
        end else if (!stall_stg1) begin
            stg0_valid <= in_valid;
            if (in_valid) begin
                for (int i = 0; i < 64; i++)
                    stg0_data[i] <= dense_in[i];
            end
        end
    end

    // =========================================================================
    // STAGE 1: 2:4 Selection combinational logic
    // For each group of 4 values, select the 2 with largest |magnitude|
    // =========================================================================
    logic signed [7:0] s1_sparse_comb [0:31];
    logic [2:0]        s1_meta_comb   [0:15];

    always_comb begin
        // Initialize outputs to prevent X propagation
        for (int i = 0; i < 32; i++) s1_sparse_comb[i] = 8'h0;
        for (int i = 0; i < 16; i++) s1_meta_comb[i]   = 3'h0;
        
        // Process each group of 4 elements
        for (int g = 0; g < GROUPS; g++) begin
            // Extract group elements and compute absolute values
            for (int k = 0; k < 4; k++) begin
                s1_v[g][k]     = stg0_data[g*4 + k];
                s1_abs_v[g][k] = s1_v[g][k][7] ? (-s1_v[g][k]) : s1_v[g][k];
            end

            // Find the two elements with largest magnitude
            // Find max
            s1_sel0[g] = 2'd0;
            if (s1_abs_v[g][1] > s1_abs_v[g][s1_sel0[g]]) s1_sel0[g] = 2'd1;
            if (s1_abs_v[g][2] > s1_abs_v[g][s1_sel0[g]]) s1_sel0[g] = 2'd2;
            if (s1_abs_v[g][3] > s1_abs_v[g][s1_sel0[g]]) s1_sel0[g] = 2'd3;

            // Find second max (different from sel0)
            s1_sel1[g] = (s1_sel0[g] == 2'd0) ? 2'd1 : 2'd0;
            for (int k = 0; k < 4; k++) begin
                if (2'(k) != s1_sel0[g] && s1_abs_v[g][k] > s1_abs_v[g][s1_sel1[g]])
                    s1_sel1[g] = 2'(k);
            end

            // Ensure canonical ordering (low index first)
            if (s1_sel0[g] > s1_sel1[g]) begin
                // ✅ STEP 1 FIX: Removed 'logic [1:0] tmp;' declaration from here
                tmp = s1_sel0[g]; 
                s1_sel0[g] = s1_sel1[g]; 
                s1_sel1[g] = tmp;
            end

            // Encode selected positions (6 possible states)
            case ({s1_sel0[g], s1_sel1[g]})
                {2'd0, 2'd1}: s1_meta_comb[g] = 3'b000;
                {2'd0, 2'd2}: s1_meta_comb[g] = 3'b001;
                {2'd0, 2'd3}: s1_meta_comb[g] = 3'b010;
                {2'd1, 2'd2}: s1_meta_comb[g] = 3'b011;
                {2'd1, 2'd3}: s1_meta_comb[g] = 3'b100;
                {2'd2, 2'd3}: s1_meta_comb[g] = 3'b101;
                default:       s1_meta_comb[g] = 3'b000;
            endcase

            // Assign selected values to output
            s1_sparse_comb[g*2]   = s1_v[g][s1_sel0[g]];
            s1_sparse_comb[g*2+1] = s1_v[g][s1_sel1[g]];
        end
    end

    // =========================================================================
    // STAGE 1 REGISTER
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stg1_valid <= 1'b0;
            for (int i = 0; i < 32; i++) stg1_sparse[i] <= 8'h0;
            // NORM-015 FIX: Explicitly reset stg1_meta
            for (int i = 0; i < 16; i++) stg1_meta[i] <= 3'h0;
        end else if (!stall_stg1) begin
            stg1_valid <= stg0_valid;
            if (stg0_valid) begin
                for (int i = 0; i < 32; i++) stg1_sparse[i] <= s1_sparse_comb[i];
                for (int i = 0; i < 16; i++) stg1_meta[i] <= s1_meta_comb[i];
            end
        end
    end

    // =========================================================================
    // STAGE 2 REGISTER (prefix-sum placeholder)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stg2_valid <= 1'b0;
            for (int i = 0; i < 32; i++) stg2_sparse[i] <= 8'h0;
            for (int i = 0; i < 16; i++) stg2_meta[i]   <= 3'h0;
        end else if (!stall_stg2) begin
            stg2_valid <= stg1_valid;
            if (stg1_valid) begin
                for (int i = 0; i < 32; i++) stg2_sparse[i] <= stg1_sparse[i];
                for (int i = 0; i < 16; i++) stg2_meta[i]   <= stg1_meta[i];
            end
        end
    end

    // =========================================================================
    // OUTPUT REGISTERS
    // FIX SPARSE-HS-001: Gate output update on backpressure.
    // Condition !(out_valid_reg && !out_ready) evaluates to:
    //   - not stalled (no valid output, or output accepted) → update
    //   - stalled (valid output but consumer not ready)     → hold
    // This prevents stg2 data from overwriting a beat that the consumer
    // has not yet consumed.
    // =========================================================================
    logic signed [7:0] sparse_out_reg [0:31]; 
    logic [2:0]        meta_out_reg   [0:15]; 
    logic [5:0]        nz_count_out_reg;
    logic              out_valid_reg;
    
    // Non-zero count calculation signal declaration
    logic [5:0] nz_count_calc;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 32; i++) sparse_out_reg[i] <= 8'h0;
            for (int i = 0; i < 16; i++) meta_out_reg[i] <= 3'h0;
            nz_count_out_reg <= 6'd0;
            out_valid_reg <= 1'b0;
        end else if (!(out_valid_reg && !out_ready)) begin
            // FIX SPARSE-HS-001: Only update when not stalled
            // Register outputs to ensure data and valid are synchronized
            for (int i = 0; i < 32; i++) sparse_out_reg[i] <= stg2_sparse[i];
            for (int i = 0; i < 16; i++) meta_out_reg[i] <= stg2_meta[i];
            nz_count_out_reg <= nz_count_calc;
            out_valid_reg <= stg2_valid;
        end
        // else: hold all output registers (consumer is stalled)
    end
    
    // CRIT-008 FIX: Only use registered outputs
    assign sparse_out = sparse_out_reg;
    assign meta_out = meta_out_reg;
    assign nz_count_out = nz_count_out_reg;
    assign out_valid = out_valid_reg;
    
    // =========================================================================
    // NON-ZERO COUNT CALCULATION
    // SYNTH-SPARSE FIX: Changed loop variable from logic to int
    // =========================================================================
    
    always_comb begin
        nz_count_calc = 6'd0;
        // ✅ CRITICAL FIX: Changed from logic [5:0] j to int j
        for (int j = 0; j < 32; j++) begin
            if (stg2_sparse[j] != 8'h0) begin
                nz_count_calc = nz_count_calc + 6'd1;
            end
        end
    end

endmodule