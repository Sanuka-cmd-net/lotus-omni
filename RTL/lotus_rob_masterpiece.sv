`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// lotus_rob_masterpiece - V7.7 TIMING FIX (REGISTERED rob_valid IN CDB WRITEBACK)
// Engineer:      Sanuka Nethmira Amarasekara (Lotus Omni)
// Target:        Xilinx Artix-7 xc7a200t
//
// FIX V7.7 (THIS VERSION): Use REGISTERED rob_valid in CDB writeback (Step 2).
//   Critical path (timing_fix4): occupancy_local_reg -> tail -> disp_ptr ->
//   n_rob_valid -> CDB writeback -> n_rob_exc_valid -> rob_exc_valid_reg/D
//   (13 levels, -1.343ns WNS).
//
//   Root cause: Step 2 used n_rob_valid (combinational, depends on the dispatch
//   path occupancy -> tail -> disp_ptr), coupling CDB writeback to that deep chain.
//
//   Fix: CDB writeback targets PREVIOUSLY dispatched entries, so the REGISTERED
//   rob_valid already holds the correct valid bit. Using rob_valid (registered)
//   instead of n_rob_valid decouples CDB writeback from the dispatch path.
//   Functionally equivalent (a same-cycle dispatch cannot be the CDB target).
//
// Previous fixes preserved: V7.6 parallel commit pre-extraction, V7.5 banked RAM,
// V7.4 parameterized bit-select.
//////////////////////////////////////////////////////////////////////////////////

module lotus_rob_masterpiece import lotus_pkg::*; #(
    parameter ROB_ENTRIES    = 64,
    parameter DISPATCH_WIDTH = 4,
    parameter COMMIT_WIDTH   = 4
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,
    output logic        flush_req,
    output logic [63:0] flush_target_pc,
    input  logic [63:0] mtvec,

    input  renamed_uop_t dispatch_uop   [0:DISPATCH_WIDTH-1],
    input  logic [3:0]   dispatch_valid,
    output logic         rob_ready,
    output logic [6:0]   alloc_rob_idx  [0:DISPATCH_WIDTH-1],

    input  logic [3:0]   cdb_valid,
    input  logic [6:0]   cdb_rob_idx [0:3],
    input  logic [63:0]  cdb_data    [0:3],
    input  logic [3:0]   cdb_exception,
    input  logic [63:0]  cdb_exc_cause [0:3],

    output logic [6:0]   commit_p_dest      [0:COMMIT_WIDTH-1],
    output logic [6:0]   commit_p_old_dest  [0:COMMIT_WIDTH-1],
    output logic [63:0]  commit_data        [0:COMMIT_WIDTH-1],
    output logic [3:0]   commit_is_store,
    output logic [4:0]   commit_lsq_idx     [0:COMMIT_WIDTH-1],
    output logic [6:0]   commit_rob_idx     [0:COMMIT_WIDTH-1],
    output logic [3:0]   commit_valid,
    input  logic [3:0]   commit_ack,

    output logic         exception_valid,
    output logic [63:0]  exception_cause,
    output logic [63:0]  exception_pc,

    output logic [7:0]   rob_occupancy,
    output logic         rob_full,
    output logic         rob_empty
);

    localparam ROB_IDX_W         = $clog2(ROB_ENTRIES);
    localparam ROB_SAFETY_MARGIN = 16;
    localparam BANK_DEPTH        = ROB_ENTRIES / DISPATCH_WIDTH;
    localparam BANK_IDX_W        = $clog2(BANK_DEPTH);

    // =========================================================================
    // Control state (flip-flops)
    // =========================================================================
    logic        rob_valid     [0:ROB_ENTRIES-1];
    logic        rob_completed [0:ROB_ENTRIES-1];
    logic        rob_is_store  [0:ROB_ENTRIES-1];
    logic        rob_exc_valid [0:ROB_ENTRIES-1];
    logic [63:0] rob_exc_cause [0:ROB_ENTRIES-1];
    logic [63:0] rob_comp_data [0:ROB_ENTRIES-1];

    // =========================================================================
    // BANKED RAM Arrays (FIX V7.3 - Distributed for Async Read)
    // =========================================================================
    (* ram_style = "distributed" *) logic [63:0] pload_pc_b0         [0:BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [63:0] pload_pc_b1         [0:BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [63:0] pload_pc_b2         [0:BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [63:0] pload_pc_b3         [0:BANK_DEPTH-1];

    (* ram_style = "distributed" *) logic [6:0]  pload_p_dest_b0     [0:BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [6:0]  pload_p_dest_b1     [0:BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [6:0]  pload_p_dest_b2     [0:BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [6:0]  pload_p_dest_b3     [0:BANK_DEPTH-1];

    (* ram_style = "distributed" *) logic [6:0]  pload_p_old_dest_b0 [0:BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [6:0]  pload_p_old_dest_b1 [0:BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [6:0]  pload_p_old_dest_b2 [0:BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [6:0]  pload_p_old_dest_b3 [0:BANK_DEPTH-1];

    logic [ROB_IDX_W-1:0] head;
    logic [ROB_IDX_W-1:0] tail;
    logic [7:0]           occupancy_local;

    assign rob_occupancy = occupancy_local;
    assign rob_ready     = (occupancy_local < ROB_ENTRIES - ROB_SAFETY_MARGIN);
    assign alloc_rob_idx[0] = tail;
    assign alloc_rob_idx[1] = (tail + 1'b1) & (ROB_ENTRIES-1);
    assign alloc_rob_idx[2] = (tail + 2'd2) & (ROB_ENTRIES-1);
    assign alloc_rob_idx[3] = (tail + 2'd3) & (ROB_ENTRIES-1);
    assign rob_full  = (occupancy_local == ROB_ENTRIES);
    assign rob_empty = (occupancy_local == 0);

    // =========================================================================
    // RAM Write Logic (Synchronous) - SINGLE WRITE PORT PER BANK
    // =========================================================================
    logic [ROB_IDX_W-1:0] pload_we_ptr      [0:DISPATCH_WIDTH-1];
    logic                 pload_we_en        [0:DISPATCH_WIDTH-1];
    logic [63:0]          pload_pc_w        [0:DISPATCH_WIDTH-1];
    logic [6:0]           pload_p_dest_w    [0:DISPATCH_WIDTH-1];
    logic [6:0]           pload_p_old_dest_w[0:DISPATCH_WIDTH-1];

    always_comb begin
        logic [ROB_IDX_W-1:0] aptr;
        aptr = tail;
        for (int i = 0; i < DISPATCH_WIDTH; i++) begin
            pload_we_en[i]          = 1'b0;
            pload_we_ptr[i]         = aptr;
            pload_pc_w[i]           = dispatch_uop[i].pc;
            pload_p_dest_w[i]       = dispatch_uop[i].p_dest;
            pload_p_old_dest_w[i]   = dispatch_uop[i].p_old_dest;
            if (dispatch_valid[i] && (occupancy_local + 8'(i) < ROB_ENTRIES)) begin
                pload_we_en[i] = 1'b1;
                aptr = (aptr + 1'b1) & (ROB_ENTRIES-1);
            end
        end
    end

    // Bank 0 Write
    always_ff @(posedge clk) begin
        if (pload_we_en[0] && pload_we_ptr[0][1:0] == 2'b00) begin
            pload_pc_b0[pload_we_ptr[0][ROB_IDX_W-1:2]]         <= pload_pc_w[0];
            pload_p_dest_b0[pload_we_ptr[0][ROB_IDX_W-1:2]]     <= pload_p_dest_w[0];
            pload_p_old_dest_b0[pload_we_ptr[0][ROB_IDX_W-1:2]] <= pload_p_old_dest_w[0];
        end else if (pload_we_en[1] && pload_we_ptr[1][1:0] == 2'b00) begin
            pload_pc_b0[pload_we_ptr[1][ROB_IDX_W-1:2]]         <= pload_pc_w[1];
            pload_p_dest_b0[pload_we_ptr[1][ROB_IDX_W-1:2]]     <= pload_p_dest_w[1];
            pload_p_old_dest_b0[pload_we_ptr[1][ROB_IDX_W-1:2]] <= pload_p_old_dest_w[1];
        end else if (pload_we_en[2] && pload_we_ptr[2][1:0] == 2'b00) begin
            pload_pc_b0[pload_we_ptr[2][ROB_IDX_W-1:2]]         <= pload_pc_w[2];
            pload_p_dest_b0[pload_we_ptr[2][ROB_IDX_W-1:2]]     <= pload_p_dest_w[2];
            pload_p_old_dest_b0[pload_we_ptr[2][ROB_IDX_W-1:2]] <= pload_p_old_dest_w[2];
        end else if (pload_we_en[3] && pload_we_ptr[3][1:0] == 2'b00) begin
            pload_pc_b0[pload_we_ptr[3][ROB_IDX_W-1:2]]         <= pload_pc_w[3];
            pload_p_dest_b0[pload_we_ptr[3][ROB_IDX_W-1:2]]     <= pload_p_dest_w[3];
            pload_p_old_dest_b0[pload_we_ptr[3][ROB_IDX_W-1:2]] <= pload_p_old_dest_w[3];
        end
    end

    // Bank 1 Write
    always_ff @(posedge clk) begin
        if (pload_we_en[0] && pload_we_ptr[0][1:0] == 2'b01) begin
            pload_pc_b1[pload_we_ptr[0][ROB_IDX_W-1:2]]         <= pload_pc_w[0];
            pload_p_dest_b1[pload_we_ptr[0][ROB_IDX_W-1:2]]     <= pload_p_dest_w[0];
            pload_p_old_dest_b1[pload_we_ptr[0][ROB_IDX_W-1:2]] <= pload_p_old_dest_w[0];
        end else if (pload_we_en[1] && pload_we_ptr[1][1:0] == 2'b01) begin
            pload_pc_b1[pload_we_ptr[1][ROB_IDX_W-1:2]]         <= pload_pc_w[1];
            pload_p_dest_b1[pload_we_ptr[1][ROB_IDX_W-1:2]]     <= pload_p_dest_w[1];
            pload_p_old_dest_b1[pload_we_ptr[1][ROB_IDX_W-1:2]] <= pload_p_old_dest_w[1];
        end else if (pload_we_en[2] && pload_we_ptr[2][1:0] == 2'b01) begin
            pload_pc_b1[pload_we_ptr[2][ROB_IDX_W-1:2]]         <= pload_pc_w[2];
            pload_p_dest_b1[pload_we_ptr[2][ROB_IDX_W-1:2]]     <= pload_p_dest_w[2];
            pload_p_old_dest_b1[pload_we_ptr[2][ROB_IDX_W-1:2]] <= pload_p_old_dest_w[2];
        end else if (pload_we_en[3] && pload_we_ptr[3][1:0] == 2'b01) begin
            pload_pc_b1[pload_we_ptr[3][ROB_IDX_W-1:2]]         <= pload_pc_w[3];
            pload_p_dest_b1[pload_we_ptr[3][ROB_IDX_W-1:2]]     <= pload_p_dest_w[3];
            pload_p_old_dest_b1[pload_we_ptr[3][ROB_IDX_W-1:2]] <= pload_p_old_dest_w[3];
        end
    end

    // Bank 2 Write
    always_ff @(posedge clk) begin
        if (pload_we_en[0] && pload_we_ptr[0][1:0] == 2'b10) begin
            pload_pc_b2[pload_we_ptr[0][ROB_IDX_W-1:2]]         <= pload_pc_w[0];
            pload_p_dest_b2[pload_we_ptr[0][ROB_IDX_W-1:2]]     <= pload_p_dest_w[0];
            pload_p_old_dest_b2[pload_we_ptr[0][ROB_IDX_W-1:2]] <= pload_p_old_dest_w[0];
        end else if (pload_we_en[1] && pload_we_ptr[1][1:0] == 2'b10) begin
            pload_pc_b2[pload_we_ptr[1][ROB_IDX_W-1:2]]         <= pload_pc_w[1];
            pload_p_dest_b2[pload_we_ptr[1][ROB_IDX_W-1:2]]     <= pload_p_dest_w[1];
            pload_p_old_dest_b2[pload_we_ptr[1][ROB_IDX_W-1:2]] <= pload_p_old_dest_w[1];
        end else if (pload_we_en[2] && pload_we_ptr[2][1:0] == 2'b10) begin
            pload_pc_b2[pload_we_ptr[2][ROB_IDX_W-1:2]]         <= pload_pc_w[2];
            pload_p_dest_b2[pload_we_ptr[2][ROB_IDX_W-1:2]]     <= pload_p_dest_w[2];
            pload_p_old_dest_b2[pload_we_ptr[2][ROB_IDX_W-1:2]] <= pload_p_old_dest_w[2];
        end else if (pload_we_en[3] && pload_we_ptr[3][1:0] == 2'b10) begin
            pload_pc_b2[pload_we_ptr[3][ROB_IDX_W-1:2]]         <= pload_pc_w[3];
            pload_p_dest_b2[pload_we_ptr[3][ROB_IDX_W-1:2]]     <= pload_p_dest_w[3];
            pload_p_old_dest_b2[pload_we_ptr[3][ROB_IDX_W-1:2]] <= pload_p_old_dest_w[3];
        end
    end

    // Bank 3 Write
    always_ff @(posedge clk) begin
        if (pload_we_en[0] && pload_we_ptr[0][1:0] == 2'b11) begin
            pload_pc_b3[pload_we_ptr[0][ROB_IDX_W-1:2]]         <= pload_pc_w[0];
            pload_p_dest_b3[pload_we_ptr[0][ROB_IDX_W-1:2]]     <= pload_p_dest_w[0];
            pload_p_old_dest_b3[pload_we_ptr[0][ROB_IDX_W-1:2]] <= pload_p_old_dest_w[0];
        end else if (pload_we_en[1] && pload_we_ptr[1][1:0] == 2'b11) begin
            pload_pc_b3[pload_we_ptr[1][ROB_IDX_W-1:2]]         <= pload_pc_w[1];
            pload_p_dest_b3[pload_we_ptr[1][ROB_IDX_W-1:2]]     <= pload_p_dest_w[1];
            pload_p_old_dest_b3[pload_we_ptr[1][ROB_IDX_W-1:2]] <= pload_p_old_dest_w[1];
        end else if (pload_we_en[2] && pload_we_ptr[2][1:0] == 2'b11) begin
            pload_pc_b3[pload_we_ptr[2][ROB_IDX_W-1:2]]         <= pload_pc_w[2];
            pload_p_dest_b3[pload_we_ptr[2][ROB_IDX_W-1:2]]     <= pload_p_dest_w[2];
            pload_p_old_dest_b3[pload_we_ptr[2][ROB_IDX_W-1:2]] <= pload_p_old_dest_w[2];
        end else if (pload_we_en[3] && pload_we_ptr[3][1:0] == 2'b11) begin
            pload_pc_b3[pload_we_ptr[3][ROB_IDX_W-1:2]]         <= pload_pc_w[3];
            pload_p_dest_b3[pload_we_ptr[3][ROB_IDX_W-1:2]]     <= pload_p_dest_w[3];
            pload_p_old_dest_b3[pload_we_ptr[3][ROB_IDX_W-1:2]] <= pload_p_old_dest_w[3];
        end
    end

    // =========================================================================
    // FIX V7.5 - Combinational Read Logic & Pre-Extracted MUXes (NO CDB bypass)
    // =========================================================================
    logic [63:0] commit_pc_read      [0:COMMIT_WIDTH-1];
    logic [6:0]  commit_p_dest_read  [0:COMMIT_WIDTH-1];
    logic [6:0]  commit_p_old_dest_read [0:COMMIT_WIDTH-1];
    logic [ROB_IDX_W-1:0] commit_c_idx [0:COMMIT_WIDTH-1];

    logic [63:0] commit_exc_cause_mux [0:COMMIT_WIDTH-1];
    logic [63:0] commit_comp_data_mux [0:COMMIT_WIDTH-1];
    logic        commit_exc_valid_mux [0:COMMIT_WIDTH-1];
    logic        commit_completed_mux [0:COMMIT_WIDTH-1];
    logic        commit_is_store_mux  [0:COMMIT_WIDTH-1];

    always_comb begin
        for (int i = 0; i < COMMIT_WIDTH; i++) begin
            commit_c_idx[i] = (head + ROB_IDX_W'(i)) & (ROB_ENTRIES-1);

            case (commit_c_idx[i][1:0])
                2'b00: begin
                    commit_pc_read[i]         = pload_pc_b0[commit_c_idx[i][ROB_IDX_W-1:2]];
                    commit_p_dest_read[i]     = pload_p_dest_b0[commit_c_idx[i][ROB_IDX_W-1:2]];
                    commit_p_old_dest_read[i] = pload_p_old_dest_b0[commit_c_idx[i][ROB_IDX_W-1:2]];
                end
                2'b01: begin
                    commit_pc_read[i]         = pload_pc_b1[commit_c_idx[i][ROB_IDX_W-1:2]];
                    commit_p_dest_read[i]     = pload_p_dest_b1[commit_c_idx[i][ROB_IDX_W-1:2]];
                    commit_p_old_dest_read[i] = pload_p_old_dest_b1[commit_c_idx[i][ROB_IDX_W-1:2]];
                end
                2'b10: begin
                    commit_pc_read[i]         = pload_pc_b2[commit_c_idx[i][ROB_IDX_W-1:2]];
                    commit_p_dest_read[i]     = pload_p_dest_b2[commit_c_idx[i][ROB_IDX_W-1:2]];
                    commit_p_old_dest_read[i] = pload_p_old_dest_b2[commit_c_idx[i][ROB_IDX_W-1:2]];
                end
                2'b11: begin
                    commit_pc_read[i]         = pload_pc_b3[commit_c_idx[i][ROB_IDX_W-1:2]];
                    commit_p_dest_read[i]     = pload_p_dest_b3[commit_c_idx[i][ROB_IDX_W-1:2]];
                    commit_p_old_dest_read[i] = pload_p_old_dest_b3[commit_c_idx[i][ROB_IDX_W-1:2]];
                end
            endcase

            commit_exc_cause_mux[i] = rob_exc_cause[commit_c_idx[i]];
            commit_comp_data_mux[i] = rob_comp_data[commit_c_idx[i]];
            commit_exc_valid_mux[i] = rob_exc_valid[commit_c_idx[i]];
            commit_completed_mux[i] = rob_completed[commit_c_idx[i]];
            commit_is_store_mux[i]  = rob_is_store[commit_c_idx[i]];
        end
    end

    // =========================================================================
    // Combinational next-state
    // =========================================================================
    logic        n_rob_valid     [0:ROB_ENTRIES-1];
    logic        n_rob_completed [0:ROB_ENTRIES-1];
    logic        n_rob_is_store  [0:ROB_ENTRIES-1];
    logic        n_rob_exc_valid [0:ROB_ENTRIES-1];
    logic [63:0] n_rob_exc_cause [0:ROB_ENTRIES-1];
    logic [63:0] n_rob_comp_data [0:ROB_ENTRIES-1];

    logic [ROB_IDX_W-1:0] n_head;
    logic [ROB_IDX_W-1:0] n_tail;
    logic [7:0]           n_occupancy;
    logic                 n_flush_req;
    logic [63:0]          n_flush_target_pc;
    logic                 n_exception_valid;
    logic [63:0]          n_exception_cause;
    logic [63:0]          n_exception_pc;

    always_comb begin
        integer i, p;
        logic [ROB_IDX_W-1:0] disp_ptr;
        logic [3:0] disp_cnt, commit_cnt;
        logic [7:0] retire_cnt;
        logic       exc_found;

        for (i = 0; i < ROB_ENTRIES; i++) begin
            n_rob_valid[i]     = rob_valid[i];
            n_rob_completed[i] = rob_completed[i];
            n_rob_is_store[i]  = rob_is_store[i];
            n_rob_exc_valid[i] = rob_exc_valid[i];
            n_rob_exc_cause[i] = rob_exc_cause[i];
            n_rob_comp_data[i] = rob_comp_data[i];
        end
        n_head            = head;
        n_tail            = tail;
        n_occupancy       = occupancy_local;
        n_flush_req       = 1'b0;
        n_flush_target_pc = mtvec;
        n_exception_valid = 1'b0;
        n_exception_cause = 64'h0;
        n_exception_pc    = 64'h0;

        // Step 1: Dispatch
        disp_ptr = tail;
        disp_cnt = 4'h0;
        for (i = 0; i < DISPATCH_WIDTH; i++) begin
            if (dispatch_valid[i] && (n_occupancy + 8'(disp_cnt) < ROB_ENTRIES)) begin
                n_rob_valid[disp_ptr]     = 1'b1;
                n_rob_completed[disp_ptr] = 1'b0;
                n_rob_is_store[disp_ptr]  = dispatch_uop[i].is_memory && !dispatch_uop[i].is_branch;
                n_rob_exc_valid[disp_ptr] = 1'b0;
                n_rob_exc_cause[disp_ptr] = 64'h0;
                disp_ptr = (disp_ptr + 1'b1) & (ROB_ENTRIES-1);
                disp_cnt = disp_cnt + 1;
            end
        end
        n_tail = disp_ptr;

        // =====================================================================
        // Step 2: CDB writeback
        // === FIX V7.7: Use REGISTERED rob_valid (was n_rob_valid) ===
        //   CDB targets previously-dispatched entries; the registered rob_valid
        //   already holds the correct bit. This removes the dispatch-path
        //   dependency (occupancy -> tail -> disp_ptr -> n_rob_valid) from the
        //   CDB writeback chain that fed rob_exc_valid_reg/D (-1.343ns).
        // =====================================================================
        for (p = 0; p < 4; p++) begin
            if (cdb_valid[p] && rob_valid[cdb_rob_idx[p]]) begin   // <-- rob_valid (REGISTERED)
                n_rob_completed[cdb_rob_idx[p]] = 1'b1;
                n_rob_exc_valid[cdb_rob_idx[p]] = cdb_exception[p];
                n_rob_exc_cause[cdb_rob_idx[p]] = cdb_exc_cause[p];
                n_rob_comp_data[cdb_rob_idx[p]] = cdb_data[p];
            end
        end

        // Step 3: Commit (uses pre-extracted MUXes - no bypass)
        commit_cnt = 4'h0;
        retire_cnt = 8'h0;
        exc_found  = 1'b0;
        for (i = 0; i < COMMIT_WIDTH; i++) begin
            if (!exc_found && commit_ack[i]) begin
                if (commit_exc_valid_mux[i]) begin
                    n_flush_req       = 1'b1;
                    n_flush_target_pc = mtvec;
                    n_exception_valid = 1'b1;
                    n_exception_cause = commit_exc_cause_mux[i];
                    n_exception_pc    = commit_pc_read[i];
                    exc_found         = 1'b1;
                end else begin
                    n_rob_valid[commit_c_idx[i]] = 1'b0;
                    commit_cnt         = commit_cnt + 1;
                    retire_cnt         = retire_cnt + 1;
                end
            end
        end

        n_head      = (head + ROB_IDX_W'(commit_cnt)) & (ROB_ENTRIES-1);
        n_occupancy = (n_occupancy + 8'(disp_cnt) >= retire_cnt)
                      ? (n_occupancy + 8'(disp_cnt) - retire_cnt) : 8'h0;
    end

    // =========================================================================
    // Sequential update
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ROB_ENTRIES; i++) begin
                rob_valid[i]     <= 1'b0;
                rob_completed[i] <= 1'b0;
                rob_is_store[i]  <= 1'b0;
                rob_exc_valid[i] <= 1'b0;
                rob_exc_cause[i] <= 64'h0;
                rob_comp_data[i] <= 64'h0;
            end
            head            <= '0;
            tail            <= '0;
            occupancy_local <= 8'h0;
            flush_req       <= 1'b0;
            flush_target_pc <= 64'h0;
            exception_valid <= 1'b0;
            exception_cause <= 64'h0;
            exception_pc    <= 64'h0;
        end else if (flush) begin
            for (int i = 0; i < ROB_ENTRIES; i++) rob_valid[i] <= 1'b0;
            head            <= '0;
            tail            <= '0;
            occupancy_local <= 8'h0;
            flush_req       <= 1'b0;
            exception_valid <= 1'b0;
        end else begin
            for (int i = 0; i < ROB_ENTRIES; i++) begin
                rob_valid[i]     <= n_rob_valid[i];
                rob_completed[i] <= n_rob_completed[i];
                rob_is_store[i]  <= n_rob_is_store[i];
                rob_exc_valid[i] <= n_rob_exc_valid[i];
                rob_exc_cause[i] <= n_rob_exc_cause[i];
                rob_comp_data[i] <= n_rob_comp_data[i];
            end
            head            <= n_head;
            tail            <= n_tail;
            occupancy_local <= n_occupancy;
            flush_req       <= n_flush_req;
            flush_target_pc <= n_flush_target_pc;
            exception_valid <= n_exception_valid;
            exception_cause <= n_exception_cause;
            exception_pc    <= n_exception_pc;
        end
    end

    // =========================================================================
    // Output Commit Logic (Combinational) - FIX V7.5 / V7.6
    // =========================================================================
    always_comb begin
        logic c_exc_found;

        c_exc_found = 1'b0;

        for (int i = 0; i < COMMIT_WIDTH; i++) begin
            commit_valid[i]      = 1'b0;
            commit_p_dest[i]     = '0;
            commit_p_old_dest[i] = '0;
            commit_data[i]       = 64'h0;
            commit_rob_idx[i]    = '0;
            commit_lsq_idx[i]    = 5'h0;

            if (!c_exc_found) begin
                if (rob_valid[commit_c_idx[i]] && commit_completed_mux[i]) begin
                    commit_p_dest[i]     = commit_p_dest_read[i];
                    commit_p_old_dest[i] = commit_p_old_dest_read[i];
                    commit_data[i]       = commit_comp_data_mux[i];
                    commit_rob_idx[i]    = commit_c_idx[i];
                    commit_lsq_idx[i]    = 5'h0;
                    commit_valid[i]      = 1'b1;
                    if (commit_exc_valid_mux[i]) c_exc_found = 1'b1;
                end
            end
        end
    end

    assign commit_is_store = {
        (commit_valid[3] ? commit_is_store_mux[3] : 1'b0),
        (commit_valid[2] ? commit_is_store_mux[2] : 1'b0),
        (commit_valid[1] ? commit_is_store_mux[1] : 1'b0),
        (commit_valid[0] ? commit_is_store_mux[0] : 1'b0)
    };

endmodule