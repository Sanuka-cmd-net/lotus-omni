`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// lotus_lsq_masterpiece - V3.6 TIMING OPTIMIZED
// Engineer:      Sanuka Nethmira Amarasekara (Lotus Omni)
// Target:        Xilinx Artix-7 xc7a200t
//
// FIX LSQ-004/005/006 : (preserved) committed_cnt / reset / data-reg splits.
// FIX LSQ-TIMING-01   : (preserved) Vectorized forwarding (CAM-style parallel).
// FIX LSQ-TIMING-02   : (preserved) Registered-commit flush protection.
// FIX LSQ-TIMING-03   : (preserved) 2-cycle forwarding pipeline.
// FIX LSQ-TIMING-03b  : (preserved) Shallow drain-hold (head_fwd_match).
//
// FIX LSQ-TIMING-04 (V3.6): DRAIN DATA PATH OPTIMIZATION.
//   1. Removed dead code: committed_cnt_comb (computed but never used).
//   2. Drain data/addr/wmask now read from REGISTERED sq_array[sq_head]
//      instead of combinational n_sq_array[n_sq_head]. This removes the
//      AGU store-update MUX (16-entry search) from the l1d_req_data D-pin
//      path, reducing logic depth by ~4 levels.
//      Safe because: head is committed → AGU data already in sq_array
//      (AGU update precedes commit in pipeline order).
//   3. Drain condition still uses n_sq_array for valid/committed because
//      commit mark may set committed=1 in the SAME cycle.
//////////////////////////////////////////////////////////////////////////////////

module lotus_lsq_masterpiece import lotus_pkg::*; #(
    parameter SQ_DEPTH   = 16,
    parameter ADDR_WIDTH = 64,
    parameter DATA_WIDTH = 64
)(
    input  logic clk, rst_n, flush,
    input  logic                  alloc_valid,
    input  logic                  alloc_is_store,
    input  logic [6:0]            alloc_rob_idx,
    output logic                  sq_ready,
    output logic [4:0]            alloc_sq_idx,
    input  logic                  agu_valid,
    input  logic                  agu_is_store,
    input  logic [6:0]            agu_rob_idx,
    input  logic [ADDR_WIDTH-1:0] agu_addr,
    input  logic [DATA_WIDTH-1:0] agu_data,
    input  logic [7:0]            agu_wmask,
    output logic                  load_fwd_valid,
    output logic [DATA_WIDTH-1:0] load_fwd_data,
    output logic                  load_needs_cache,
    input  logic [3:0]            commit_valid,
    input  logic [3:0]            commit_is_store,
    input  logic [6:0]            commit_rob_idx [0:3],
    output logic                  l1d_req_valid,
    output logic                  l1d_req_rw,
    output logic [ADDR_WIDTH-1:0] l1d_req_addr,
    output logic [DATA_WIDTH-1:0] l1d_req_data,
    output logic [7:0]            l1d_req_wmask,
    input  logic                  l1d_req_ready
);

    sq_entry_t [SQ_DEPTH-1:0] sq_array;
    logic [3:0] sq_head, sq_tail;
    logic [4:0] sq_count;
    logic       l1d_req_in_flight;

    assign sq_ready     = (sq_count < SQ_DEPTH) && !flush;
    assign alloc_sq_idx = sq_tail;

    // =========================================================================
    // FIX LSQ-TIMING-01: Vectorized forwarding (STAGE 1 - combinational)
    // =========================================================================
    logic fwd_match, older_store_unknown_addr;
    logic [SQ_DEPTH-1:0] match_vec, unknown_addr_vec;
    logic [SQ_DEPTH-1:0] rotated_match, rotated_unknown, age_mask;
    logic [4:0]          sel_idx;
    logic [3:0]          actual_idx;
    logic                load_needs_cache_comb;

    always_comb begin
        for (int i = 0; i < SQ_DEPTH; i++) begin
            match_vec[i]        = sq_array[i].valid && sq_array[i].addr_valid &&
                                  sq_array[i].data_valid && (sq_array[i].addr == agu_addr);
            unknown_addr_vec[i] = sq_array[i].valid && !sq_array[i].addr_valid;
        end

        for (int i = 0; i < SQ_DEPTH; i++) begin
            automatic int src_idx = (sq_tail - 1 - i + SQ_DEPTH) % SQ_DEPTH;
            rotated_match[i]   = match_vec[src_idx];
            rotated_unknown[i] = unknown_addr_vec[src_idx];
        end

        age_mask = '0;
        for (int i = 0; i < SQ_DEPTH; i++)
            if (i < sq_count) age_mask[i] = 1'b1;

        older_store_unknown_addr = |(rotated_unknown & age_mask);

        sel_idx = SQ_DEPTH[4:0];
        for (int i = 0; i < SQ_DEPTH; i++) begin
            if (rotated_match[i] && age_mask[i]) begin
                sel_idx = i[4:0];
                break;
            end
        end

        fwd_match = (sel_idx < SQ_DEPTH) && !older_store_unknown_addr &&
                    agu_valid && !agu_is_store;

        actual_idx = (fwd_match) ?
                     4'((sq_tail - 1 - sel_idx + SQ_DEPTH) % SQ_DEPTH) : 4'h0;

        load_needs_cache_comb = agu_valid && !agu_is_store &&
                                !fwd_match && !older_store_unknown_addr;
    end

    // =========================================================================
    // FIX LSQ-TIMING-03b: SHALLOW head-match for drain-hold
    // =========================================================================
    logic head_fwd_match;
    always_comb begin
        head_fwd_match = agu_valid && !agu_is_store &&
                         sq_array[sq_head].valid &&
                         sq_array[sq_head].addr_valid &&
                         sq_array[sq_head].data_valid &&
                         (sq_array[sq_head].addr == agu_addr);
    end

    // =========================================================================
    // FIX LSQ-TIMING-03: STAGE 1 → STAGE 2 forwarding pipeline register
    // =========================================================================
    logic        fwd_match_q, needs_cache_q;
    logic [3:0]  actual_idx_q;
    logic [ADDR_WIDTH-1:0] load_addr_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            fwd_match_q   <= 1'b0;
            needs_cache_q <= 1'b0;
            actual_idx_q  <= 4'h0;
            load_addr_q   <= '0;
        end else begin
            fwd_match_q   <= fwd_match;
            needs_cache_q <= load_needs_cache_comb;
            actual_idx_q  <= actual_idx;
            load_addr_q   <= agu_addr;
        end
    end

    assign load_fwd_valid   = fwd_match_q;
    assign load_fwd_data    = sq_array[actual_idx_q].data;
    assign load_needs_cache = needs_cache_q;

    // =========================================================================
    // Combinational next-state
    // =========================================================================
    sq_entry_t [SQ_DEPTH-1:0] n_sq_array;
    logic [3:0]    n_sq_head, n_sq_tail;
    logic [4:0]    n_sq_count;
    logic          n_l1d_req_in_flight;
    logic          n_l1d_req_valid;
    logic          n_l1d_req_rw;
    logic [ADDR_WIDTH-1:0] n_l1d_req_addr;
    logic [DATA_WIDTH-1:0] n_l1d_req_data;
    logic [7:0]    n_l1d_req_wmask;

    // === FIX LSQ-TIMING-04: Pre-read REGISTERED head data for drain ===
    //   sq_array[sq_head] is the REGISTERED value. Safe because:
    //   - Head is committed → AGU wrote data in a PREVIOUS cycle
    //   - AGU update in THIS cycle targets a different (younger) entry
    //   This removes the 16-entry AGU MUX from the drain data path.
    logic [ADDR_WIDTH-1:0] head_data_reg;
    logic [ADDR_WIDTH-1:0] head_addr_reg;
    logic [7:0]            head_wmask_reg;
    logic                  head_valid_reg;
    logic                  head_committed_reg;

    always_comb begin
        head_data_reg     = sq_array[sq_head].data;
        head_addr_reg     = sq_array[sq_head].addr;
        head_wmask_reg    = sq_array[sq_head].wmask;
        head_valid_reg    = sq_array[sq_head].valid;
        head_committed_reg= sq_array[sq_head].committed;
    end

    always_comb begin
        integer i, j;

        for (i = 0; i < SQ_DEPTH; i++) n_sq_array[i] = sq_array[i];
        n_sq_head           = sq_head;
        n_sq_tail           = sq_tail;
        n_sq_count          = sq_count;
        n_l1d_req_in_flight = l1d_req_in_flight;
        n_l1d_req_valid     = 1'b0;
        n_l1d_req_rw        = 1'b0;
        n_l1d_req_addr      = '0;
        n_l1d_req_data      = '0;
        n_l1d_req_wmask     = '0;

        if (l1d_req_valid && l1d_req_ready)
            n_l1d_req_in_flight = 1'b0;
        else if (l1d_req_valid && !l1d_req_ready)
            n_l1d_req_in_flight = 1'b1;

        // Allocate new store
        if (alloc_valid && alloc_is_store && (n_sq_count < SQ_DEPTH) && !flush) begin
            n_sq_array[n_sq_tail].valid      = 1'b1;
            n_sq_array[n_sq_tail].addr_valid = 1'b0;
            n_sq_array[n_sq_tail].data_valid = 1'b0;
            n_sq_array[n_sq_tail].committed  = 1'b0;
            n_sq_array[n_sq_tail].rob_idx    = alloc_rob_idx;
            n_sq_tail  = (n_sq_tail + 1) % SQ_DEPTH;
            n_sq_count = n_sq_count + 1;
        end

        // AGU store update
        if (agu_valid && agu_is_store) begin
            for (i = 0; i < SQ_DEPTH; i++) begin
                if (n_sq_array[i].valid && (n_sq_array[i].rob_idx == agu_rob_idx)) begin
                    n_sq_array[i].addr_valid = 1'b1;
                    n_sq_array[i].data_valid = 1'b1;
                    n_sq_array[i].addr       = agu_addr;
                    n_sq_array[i].data       = agu_data;
                    n_sq_array[i].wmask      = agu_wmask;
                end
            end
        end

        // Commit: mark stores committed
        for (j = 0; j < 4; j++) begin
            if (commit_valid[j] && commit_is_store[j]) begin
                for (i = 0; i < SQ_DEPTH; i++)
                    if (n_sq_array[i].valid && (n_sq_array[i].rob_idx == commit_rob_idx[j]))
                        n_sq_array[i].committed = 1'b1;
            end
        end

        // =================================================================
        // Drain ONE committed store per cycle.
        // FIX LSQ-TIMING-03b: SHALLOW drain-hold (head_fwd_match).
        // FIX LSQ-TIMING-04: Use REGISTERED head data (head_data_reg)
        //   instead of n_sq_array[n_sq_head].data. Removes AGU 16-entry
        //   MUX from drain data path (~4 levels saved).
        //   Drain CONDITION still uses n_sq_array for committed because
        //   commit mark may set committed=1 in the SAME cycle.
        // =================================================================
        if (n_sq_array[n_sq_head].valid &&
            n_sq_array[n_sq_head].committed &&
            !n_l1d_req_in_flight &&
            !n_l1d_req_valid &&
            !head_fwd_match) begin
            n_l1d_req_valid             = 1'b1;
            n_l1d_req_rw                = 1'b1;
            n_l1d_req_addr              = head_addr_reg;     // REGISTERED
            n_l1d_req_data              = head_data_reg;     // REGISTERED
            n_l1d_req_wmask             = head_wmask_reg;    // REGISTERED
            n_sq_array[n_sq_head].valid = 1'b0;
            n_sq_head                   = (n_sq_head + 1) % SQ_DEPTH;
            n_sq_count                  = n_sq_count - 1;
        end

        // Load cache request (uses REGISTERED needs_cache_q + load_addr_q)
        if (!n_l1d_req_valid && needs_cache_q && !n_l1d_req_in_flight) begin
            n_l1d_req_valid = 1'b1;
            n_l1d_req_rw    = 1'b0;
            n_l1d_req_addr  = load_addr_q;
            n_l1d_req_data  = '0;
            n_l1d_req_wmask = '0;
        end
    end

    // =========================================================================
    // Sequential - CONTROL registers (async reset) + FIX LSQ-TIMING-02
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sq_head           <= '0;
            sq_tail           <= '0;
            sq_count          <= '0;
            l1d_req_valid     <= 1'b0;
            l1d_req_in_flight <= 1'b0;
            for (int i = 0; i < SQ_DEPTH; i++) sq_array[i] <= '0;
        end else begin
            if (flush) begin
                automatic logic [4:0] flush_committed_cnt = '0;
                for (int i = 0; i < SQ_DEPTH; i++) begin
                    automatic logic keep = sq_array[i].committed;
                    for (int j = 0; j < 4; j++)
                        if (commit_valid[j] && commit_is_store[j] &&
                            sq_array[i].valid && (sq_array[i].rob_idx == commit_rob_idx[j]))
                            keep = 1'b1;
                    if (!keep) sq_array[i].valid <= 1'b0;
                    else begin
                        sq_array[i].committed <= 1'b1;
                        flush_committed_cnt   = flush_committed_cnt + 1;
                    end
                end
                sq_tail           <= (sq_head + flush_committed_cnt) % SQ_DEPTH;
                sq_count          <= flush_committed_cnt;
                l1d_req_valid     <= 1'b0;
                l1d_req_in_flight <= 1'b0;
            end else begin
                sq_array          <= n_sq_array;
                sq_head           <= n_sq_head;
                sq_tail           <= n_sq_tail;
                sq_count          <= n_sq_count;
                l1d_req_in_flight <= n_l1d_req_in_flight;
                l1d_req_valid     <= n_l1d_req_valid;
            end
        end
    end

    // =========================================================================
    // FIX LSQ-006: DATA registers - NO async reset (no R pin)
    // =========================================================================
    always_ff @(posedge clk) begin
        l1d_req_rw    <= n_l1d_req_rw;
        l1d_req_addr  <= n_l1d_req_addr;
        l1d_req_data  <= n_l1d_req_data;
        l1d_req_wmask <= n_l1d_req_wmask;
    end

endmodule