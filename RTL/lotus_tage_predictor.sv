`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// Module Name:   lotus_tage_predictor - V2.8 TIMING OPTIMIZED
// Engineer:      Sanuka Nethmira Amarasekara (Lotus Omni)
//
// FIX TAGE-TIMING-01 (V2.7, preserved): Synchronous reset (no async CLR).
// FIX M1 (V2.6, preserved): Pipeline alignment for t1_q/t1_tag_q.
// FIX TAGE-001 (preserved): GHR snapshot write guarded by FIFO capacity.
// FIX TAGE-INIT-001 (preserved): Power-up initial block for all tables.
//
// FIX TAGE-TIMING-02 (V2.8): PIPELINED TRAINING UPDATE.
//   Critical path was ghr_snapshot -> tr_ghr -> tr_t2_idx/tag (XOR) ->
//   t2[256:1 mux read] -> tag compare + counter update -> t2_reg = 11 levels,
//   13.2ns (WNS -3.163ns). The index net also had fanout 1159 (broadcast to all
//   256x3 entries), adding routing delay.
//
//   Split the training path into two stages:
//     Stage 1 (cyc N):   ghr_snapshot read -> tr_ghr -> tr_t*_idx/tr_t*_tag ->
//                        REGISTER (tr_*_q). Shallow (~4ns).
//     Stage 2 (cyc N+1): registered index -> table read -> compare -> counter
//                        update -> t*_reg. Starts from a register, so the deep
//                        ghr_snapshot dependency is removed (~8ns).
//
//   Training latency increases 1 -> 2 cycles. This is a background update and
//   does NOT affect prediction latency (prediction path is already pipelined via
//   t1_q/t2_q/t3_q) or accuracy (eventual consistency of the tables).
////////////////////////////////////////////////////////////////////////////////

module lotus_tage_predictor (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [63:0] current_pc,
    output logic        pred_taken,
    output logic [63:0] pred_target,
    input  logic        resolve_valid,
    input  logic [63:0] resolve_pc,
    input  logic        resolve_taken,
    input  logic [63:0] resolve_target,
    output logic [63:0] perf_predictions,
    output logic [63:0] perf_mispredicts
);

    // =========================================================================
    // GLOBAL HISTORY REGISTER
    // =========================================================================
    logic [15:0] ghr;
    logic [63:0] last_pc;

    localparam GHR_SNAPSHOT_LATENCY   = 8;
    localparam GHR_SNAPSHOT_PTR_WIDTH = $clog2(GHR_SNAPSHOT_LATENCY);

    logic [15:0] ghr_snapshot       [0:GHR_SNAPSHOT_LATENCY-1];
    logic [GHR_SNAPSHOT_PTR_WIDTH-1:0] ghr_snap_ptr_write;
    logic [GHR_SNAPSHOT_PTR_WIDTH-1:0] ghr_snap_ptr_read;
    logic [GHR_SNAPSHOT_PTR_WIDTH:0]   ghr_entries_count;

    // =========================================================================
    // BIMODAL BASE TABLE (2^10 = 1024 entries)
    // =========================================================================
    localparam BIMODAL_BITS = 10;
    localparam BIMODAL_SIZE = 1 << BIMODAL_BITS;

    logic [1:0] bimodal [0:BIMODAL_SIZE-1];

    wire [BIMODAL_BITS-1:0] bimodal_idx = current_pc[BIMODAL_BITS+1:2];
    wire                    bimodal_pred = bimodal[bimodal_idx][1];

    // =========================================================================
    // TAGGED COMPONENTS T1, T2, T3 (256 entries each)
    // =========================================================================
    localparam T_SIZE = 256;
    localparam T_BITS = 8;

    typedef struct packed {
        logic       valid;
        logic [7:0] tag;
        logic [2:0] ctr;
    } tage_entry_t;

    tage_entry_t t1 [0:T_SIZE-1];
    tage_entry_t t2 [0:T_SIZE-1];
    tage_entry_t t3 [0:T_SIZE-1];

    wire [T_BITS-1:0] t1_idx = current_pc[T_BITS+1:2] ^ {4'h0, ghr[3:0]};
    wire [T_BITS-1:0] t2_idx = current_pc[T_BITS+1:2] ^ ghr[T_BITS-1:0];
    wire [T_BITS-1:0] t3_idx = current_pc[T_BITS+1:2] ^ ghr[15:8] ^ ghr[T_BITS-1:0];
    wire [7:0] t1_tag         = current_pc[9:2] ^ {4'h0, ghr[3:0]};
    wire [7:0] t2_tag         = current_pc[9:2] ^ ghr[7:0];
    wire [7:0] t3_tag         = current_pc[9:2] ^ ghr[15:8];

    // =========================================================================
    // Pipeline registers - 1-cycle aligned (FIX M1 from V2.6)
    // =========================================================================
    tage_entry_t       t1_q, t2_q, t3_q;
    logic [7:0]        t1_tag_q, t2_tag_q, t3_tag_q;
    logic              bimodal_pred_q;

    always_ff @(posedge clk) begin
        t1_q     <= t1[t1_idx];
        t2_q     <= t2[t2_idx];
        t3_q     <= t3[t3_idx];
        t1_tag_q <= t1_tag;
        t2_tag_q <= t2_tag;
        t3_tag_q <= t3_tag;
        bimodal_pred_q <= bimodal_pred;
    end

    wire t1_hit = t1_q.valid && (t1_q.tag == t1_tag_q);
    wire t2_hit = t2_q.valid && (t2_q.tag == t2_tag_q);
    wire t3_hit = t3_q.valid && (t3_q.tag == t3_tag_q);

    logic       pred_taken_comb;
    logic [1:0] provider;

    always_comb begin
        if      (t3_hit) begin pred_taken_comb = t3_q.ctr[2]; provider = 2'd3; end
        else if (t2_hit) begin pred_taken_comb = t2_q.ctr[2]; provider = 2'd2; end
        else if (t1_hit) begin pred_taken_comb = t1_q.ctr[2]; provider = 2'd1; end
        else             begin pred_taken_comb = bimodal_pred_q; provider = 2'd0; end
    end

    // =========================================================================
    // BTB (32 entries)
    // =========================================================================
    localparam BTB_SIZE = 32;

    typedef struct packed {
        logic        valid;
        logic [63:0] pc;
        logic [63:0] target;
    } btb_entry_t;

    btb_entry_t btb [0:BTB_SIZE-1];

    // =========================================================================
    // Power-up initialization (simulation + FPGA bitstream)
    // =========================================================================
    initial begin
        for (int i = 0; i < BIMODAL_SIZE; i++) bimodal[i] = 2'b01;
        for (int i = 0; i < T_SIZE; i++) begin
            t1[i] = '0; t2[i] = '0; t3[i] = '0;
        end
        for (int i = 0; i < BTB_SIZE; i++) btb[i] = '0;
    end

    wire [4:0]  btb_idx     = current_pc[6:2];
    wire        btb_hit     = btb[btb_idx].valid && (btb[btb_idx].pc == current_pc);
    wire [63:0] btb_target  = btb[btb_idx].target;
    wire        branch_detected = btb_hit;

    always_comb begin
        pred_taken  = pred_taken_comb;
        pred_target = (pred_taken_comb && btb_hit) ? btb_target : (current_pc + 64'd4);
    end

    // =========================================================================
    // TRAINING - snapshot-indexed index/tag computation (combinational, STAGE 1)
    // =========================================================================
    wire [15:0]             tr_ghr         = ghr_snapshot[ghr_snap_ptr_read];
    wire [BIMODAL_BITS-1:0] tr_bimodal_idx = resolve_pc[BIMODAL_BITS+1:2];
    wire [T_BITS-1:0] tr_t1_idx = resolve_pc[T_BITS+1:2] ^ {4'h0, tr_ghr[3:0]};
    wire [T_BITS-1:0] tr_t2_idx = resolve_pc[T_BITS+1:2] ^ tr_ghr[T_BITS-1:0];
    wire [T_BITS-1:0] tr_t3_idx = resolve_pc[T_BITS+1:2] ^ tr_ghr[15:8] ^ tr_ghr[T_BITS-1:0];
    wire [7:0] tr_t1_tag = resolve_pc[9:2] ^ {4'h0, tr_ghr[3:0]};
    wire [7:0] tr_t2_tag = resolve_pc[9:2] ^ tr_ghr[7:0];
    wire [7:0] tr_t3_tag = resolve_pc[9:2] ^ tr_ghr[15:8];

    // =========================================================================
    // === FIX TAGE-TIMING-02: STAGE 1 -> STAGE 2 training pipeline register ===
    //   Register the training indices/tags + resolve info. The table read +
    //   counter update (STAGE 2) now starts from these registers, removing the
    //   deep ghr_snapshot -> XOR -> index dependency from the update path.
    // =========================================================================
    logic              tr_valid_q;
    logic              tr_taken_q;
    logic [63:0]       tr_pc_q, tr_target_q;
    logic [BIMODAL_BITS-1:0] tr_bimodal_idx_q;
    logic [T_BITS-1:0] tr_t1_idx_q, tr_t2_idx_q, tr_t3_idx_q;
    logic [7:0]        tr_t1_tag_q, tr_t2_tag_q, tr_t3_tag_q;

    always_ff @(posedge clk) begin
        tr_valid_q       <= resolve_valid;
        tr_taken_q       <= resolve_taken;
        tr_pc_q          <= resolve_pc;
        tr_target_q      <= resolve_target;
        tr_bimodal_idx_q <= tr_bimodal_idx;
        tr_t1_idx_q      <= tr_t1_idx;
        tr_t2_idx_q      <= tr_t2_idx;
        tr_t3_idx_q      <= tr_t3_idx;
        tr_t1_tag_q      <= tr_t1_tag;
        tr_t2_tag_q      <= tr_t2_tag;
        tr_t3_tag_q      <= tr_t3_tag;
    end

    // =========================================================================
    // GHR + snapshot management (cycle N - unchanged, sync reset FIX TAGE-TIMING-01)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ghr                <= 16'h0;
            last_pc            <= 64'h0;
            ghr_snap_ptr_write <= '0;
            ghr_snap_ptr_read  <= '0;
            ghr_entries_count  <= '0;
            for (int i = 0; i < GHR_SNAPSHOT_LATENCY; i++)
                ghr_snapshot[i] <= 16'h0;
            perf_predictions   <= 64'h0;
            perf_mispredicts   <= 64'h0;
        end else begin
            last_pc <= current_pc;
            if (current_pc != last_pc) perf_predictions <= perf_predictions + 1;

            // FIX TAGE-001: Guard snapshot write
            if (branch_detected && current_pc != last_pc &&
                ghr_entries_count < GHR_SNAPSHOT_LATENCY) begin
                ghr_snapshot[ghr_snap_ptr_write] <= ghr;
                ghr_snap_ptr_write               <= ghr_snap_ptr_write + 1;
                ghr_entries_count                <= ghr_entries_count + 1;
            end

            if (resolve_valid) begin
                if (ghr_entries_count > 0) begin
                    ghr_snap_ptr_read <= ghr_snap_ptr_read + 1;
                    ghr_entries_count <= ghr_entries_count - 1;
                end
                ghr <= {ghr[14:0], resolve_taken};

                if (pred_taken != resolve_taken ||
                    (resolve_taken && pred_target != resolve_target))
                    perf_mispredicts <= perf_mispredicts + 1;
            end
        end
    end

    // =========================================================================
    // TABLE UPDATES (STAGE 2 - from registered indices/tags, FIX TAGE-TIMING-02)
    //   Uses tr_*_q (1 cycle after resolve). Synchronous, no reset on tables.
    // =========================================================================
    always_ff @(posedge clk) begin
        if (tr_valid_q) begin
            // Bimodal
            if  (tr_taken_q  && bimodal[tr_bimodal_idx_q] != 2'b11)
                bimodal[tr_bimodal_idx_q] <= bimodal[tr_bimodal_idx_q] + 1;
            else if (!tr_taken_q && bimodal[tr_bimodal_idx_q] != 2'b00)
                bimodal[tr_bimodal_idx_q] <= bimodal[tr_bimodal_idx_q] - 1;

            // BTB
            btb[tr_pc_q[6:2]].valid  <= 1'b1;
            btb[tr_pc_q[6:2]].pc     <= tr_pc_q;
            btb[tr_pc_q[6:2]].target <= tr_target_q;

            // T1
            if (t1[tr_t1_idx_q].valid && t1[tr_t1_idx_q].tag == tr_t1_tag_q) begin
                if  (tr_taken_q  && t1[tr_t1_idx_q].ctr != 3'b111)
                    t1[tr_t1_idx_q].ctr <= t1[tr_t1_idx_q].ctr + 1;
                else if (!tr_taken_q && t1[tr_t1_idx_q].ctr != 3'b000)
                    t1[tr_t1_idx_q].ctr <= t1[tr_t1_idx_q].ctr - 1;
            end else begin
                t1[tr_t1_idx_q] <= '{valid:1'b1, tag:tr_t1_tag_q,
                                      ctr:(tr_taken_q ? 3'b100 : 3'b011)};
            end

            // T2
            if (t2[tr_t2_idx_q].valid && t2[tr_t2_idx_q].tag == tr_t2_tag_q) begin
                if  (tr_taken_q  && t2[tr_t2_idx_q].ctr != 3'b111)
                    t2[tr_t2_idx_q].ctr <= t2[tr_t2_idx_q].ctr + 1;
                else if (!tr_taken_q && t2[tr_t2_idx_q].ctr != 3'b000)
                    t2[tr_t2_idx_q].ctr <= t2[tr_t2_idx_q].ctr - 1;
            end else begin
                t2[tr_t2_idx_q] <= '{valid:1'b1, tag:tr_t2_tag_q,
                                      ctr:(tr_taken_q ? 3'b100 : 3'b011)};
            end

            // T3
            if (t3[tr_t3_idx_q].valid && t3[tr_t3_idx_q].tag == tr_t3_tag_q) begin
                if  (tr_taken_q  && t3[tr_t3_idx_q].ctr != 3'b111)
                    t3[tr_t3_idx_q].ctr <= t3[tr_t3_idx_q].ctr + 1;
                else if (!tr_taken_q && t3[tr_t3_idx_q].ctr != 3'b000)
                    t3[tr_t3_idx_q].ctr <= t3[tr_t3_idx_q].ctr - 1;
            end else begin
                t3[tr_t3_idx_q] <= '{valid:1'b1, tag:tr_t3_tag_q,
                                      ctr:(tr_taken_q ? 3'b100 : 3'b011)};
            end
        end
    end

endmodule