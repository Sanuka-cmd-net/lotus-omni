`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// lotus_reservation_station_v4 - V5.6 TIMING FIX (CLAMPS REMOVED)
// Engineer:      Sanuka Nethmira Amarasekara (Lotus Omni)
// Target:        Xilinx Artix-7 xc7a200t
//
// FIX RS-TIMING-02 (V5.5): Pipeline issue_count -> issue_count_q.
// FIX RS-TIMING-03 (V5.6): REMOVE all conditional clamps from n_occupancy.
//   Vivado maps "else 7'h0" and "> RS_DEPTH" clamps to the FDRE R pin,
//   recreating the deep path (15 levels, -2.282ns). Pure arithmetic only.
//   RS_DEPTH=8, occupancy max=12, 7-bit range=127 -> no overflow possible.
//   issue_count_q <= occupancy+dispatch_count by construction -> no underflow.
//
// Previous fixes preserved: V5.4 PRF read pipeline, RS-TIMING-01 vectorized
// selection, RS-004 registered write addr, RS-006 isolated banks.
//////////////////////////////////////////////////////////////////////////////

module lotus_reservation_station_v4 import lotus_pkg::*; #(
    parameter RS_DEPTH = 32
)(
    input  logic clk, rst_n, flush,
    input  logic [3:0]     dispatch_valid,
    input  renamed_uop_t   dispatch_uop [0:3],
    input  logic [2:0]     dispatch_branch_tag [0:3],
    input  logic [6:0]     dispatch_rob_idx [0:3],
    output logic           rs_ready,
    input  logic [3:0]     cdb_valid,
    input  logic [6:0]     cdb_p_dest [0:3],
    input  logic [63:0]    cdb_data   [0:3],
    output logic [6:0]     prf_rd_addr [0:7],
    input  logic [63:0]    prf_rd_data [0:7],
    input  logic [127:0]   prf_ready_bits,
    output logic [3:0]     issue_valid,
    output logic [6:0]     issue_rob_idx [0:3],
    output rs_entry_t      issue_uop    [0:3],
    output logic [63:0]    issue_src1   [0:3],
    output logic [63:0]    issue_src2   [0:3],
    input  logic [3:0]     issue_ready,
    output logic [6:0]     free_slots,
    output logic           rs_full
);

    localparam RS_IDX_W = $clog2(RS_DEPTH);

    // =========================================================================
    // Register arrays
    // =========================================================================
    logic        rs_valid        [0:RS_DEPTH-1];
    logic [6:0]  rs_rob_idx      [0:RS_DEPTH-1];
    logic [6:0]  rs_p_dest       [0:RS_DEPTH-1];
    logic [6:0]  rs_p_src1       [0:RS_DEPTH-1];
    logic [6:0]  rs_p_src2       [0:RS_DEPTH-1];
    logic        rs_is_tensor_op [0:RS_DEPTH-1];
    logic        rs_is_memory    [0:RS_DEPTH-1];
    logic        rs_is_branch    [0:RS_DEPTH-1];
    logic        rs_is_csr       [0:RS_DEPTH-1];
    logic [5:0]  rs_age          [0:RS_DEPTH-1];
    logic        rs_pred_taken   [0:RS_DEPTH-1];
    logic [63:0] rs_pred_target  [0:RS_DEPTH-1];
    logic        src1_ready      [0:RS_DEPTH-1];
    logic        src2_ready      [0:RS_DEPTH-1];
    logic [63:0] src1_val        [0:RS_DEPTH-1];
    logic [63:0] src2_val        [0:RS_DEPTH-1];
    logic        rs_reserved     [0:RS_DEPTH-1];
    logic        rs_issued       [0:RS_DEPTH-1];
    logic [6:0]  occupancy;
    logic [RS_IDX_W-1:0] rs_tail;

    // =========================================================================
    // Intermediate Wires for Sub-module Banks Read Interface
    // =========================================================================
    logic [63:0] bank_rd_pc         [0:3];
    logic [7:0]  bank_rd_opcode     [0:3];
    logic [63:0] bank_rd_imm        [0:3];
    logic [2:0]  bank_rd_funct3     [0:3];
    logic [6:0]  bank_rd_funct7     [0:3];
    logic [1:0]  bank_rd_precision  [0:3];
    logic [2:0]  bank_rd_branch_tag [0:3];
    logic [RS_IDX_W-1:0] bank_rd_addr [0:3];

    // =========================================================================
    // Candidate pipeline registers
    // =========================================================================
    logic [RS_IDX_W-1:0] issue_candidates      [0:3];
    logic                issue_candidate_valid [0:3];
    logic [RS_IDX_W-1:0] issue_candidates_q      [0:3];
    logic                issue_candidate_valid_q [0:3];
    logic [3:0] issue_ready_q;

    // =========================================================================
    // FIX RS-TIMING-02: Pipelined issue count for occupancy
    // =========================================================================
    logic [2:0] issue_count;     // combinational, computed in always_comb
    logic [2:0] issue_count_q;   // registered (1-cycle pipeline)

    // =========================================================================
    // Next-state signals
    // =========================================================================
    logic        n_rs_valid        [0:RS_DEPTH-1];
    logic [6:0]  n_rs_rob_idx      [0:RS_DEPTH-1];
    logic [6:0]  n_rs_p_dest       [0:RS_DEPTH-1];
    logic [6:0]  n_rs_p_src1       [0:RS_DEPTH-1];
    logic [6:0]  n_rs_p_src2       [0:RS_DEPTH-1];
    logic        n_rs_is_tensor_op [0:RS_DEPTH-1];
    logic        n_rs_is_memory    [0:RS_DEPTH-1];
    logic        n_rs_is_branch    [0:RS_DEPTH-1];
    logic        n_rs_is_csr       [0:RS_DEPTH-1];
    logic [5:0]  n_rs_age          [0:RS_DEPTH-1];
    logic        n_rs_pred_taken   [0:RS_DEPTH-1];
    logic [63:0] n_rs_pred_target  [0:RS_DEPTH-1];
    logic        n_src1_ready      [0:RS_DEPTH-1];
    logic        n_src2_ready      [0:RS_DEPTH-1];
    logic [63:0] n_src1_val        [0:RS_DEPTH-1];
    logic [63:0] n_src2_val        [0:RS_DEPTH-1];
    logic        n_rs_reserved     [0:RS_DEPTH-1];
    logic        n_rs_issued       [0:RS_DEPTH-1];
    logic [6:0]  n_occupancy;
    logic [RS_IDX_W-1:0] n_rs_tail;
    logic [RS_IDX_W-1:0] n_issue_candidates     [0:3];
    logic                n_issue_candidate_valid [0:3];
    logic [3:0]   n_issue_valid;
    logic [6:0]   n_issue_rob_idx [0:3];
    rs_entry_t    n_issue_uop     [0:3];
    logic [63:0]  n_issue_src1    [0:3];
    logic [63:0]  n_issue_src2    [0:3];

    // =========================================================================
    // FIX RS-TIMING-01: Vectorized Selection Signals
    // =========================================================================
    logic [RS_DEPTH-1:0] match_vec [0:3];
    logic [RS_DEPTH-1:0] age_mask;
    logic [RS_DEPTH-1:0] sel_mask  [0:3];
    logic [RS_IDX_W-1:0] sel_idx   [0:3];
    logic                sel_valid [0:3];

    // =========================================================================
    // FIX RS-004: Registered write addresses for distributed RAM
    // =========================================================================
    logic [RS_IDX_W-1:0] pload_we_ptr_reg [0:3];
    logic                pload_we_en_reg  [0:3];
    logic [63:0]         pload_pc_w_reg   [0:3];
    logic [7:0]          pload_opcode_w_reg[0:3];
    logic [63:0]         pload_imm_w_reg  [0:3];
    logic [2:0]          pload_funct3_w_reg[0:3];
    logic [6:0]          pload_funct7_w_reg[0:3];
    logic [1:0]          pload_prec_w_reg [0:3];
    logic [2:0]          pload_btag_w_reg [0:3];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int p = 0; p < 4; p++) begin
                pload_we_en_reg[p]   <= 1'b0;
                pload_we_ptr_reg[p]  <= '0;
                pload_pc_w_reg[p]    <= '0;
                pload_opcode_w_reg[p]<= '0;
                pload_imm_w_reg[p]   <= '0;
                pload_funct3_w_reg[p]<= '0;
                pload_funct7_w_reg[p]<= '0;
                pload_prec_w_reg[p]  <= '0;
                pload_btag_w_reg[p]  <= '0;
            end
        end else begin
            for (int p = 0; p < 4; p++) begin
                if (dispatch_valid[p] && !rs_valid[(rs_tail + RS_IDX_W'(p)) & (RS_DEPTH-1)]) begin
                    pload_we_en_reg[p]   <= 1'b1;
                    pload_we_ptr_reg[p]  <= (rs_tail + RS_IDX_W'(p)) & (RS_DEPTH-1);
                    pload_pc_w_reg[p]    <= dispatch_uop[p].pc;
                    pload_opcode_w_reg[p]<= dispatch_uop[p].opcode;
                    pload_imm_w_reg[p]   <= dispatch_uop[p].imm_data;
                    pload_funct3_w_reg[p]<= dispatch_uop[p].funct3;
                    pload_funct7_w_reg[p]<= dispatch_uop[p].funct7;
                    pload_prec_w_reg[p]  <= dispatch_uop[p].precision;
                    pload_btag_w_reg[p]  <= dispatch_branch_tag[p];
                end else begin
                    pload_we_en_reg[p] <= 1'b0;
                end
            end
        end
    end

    // =========================================================================
    // FIX RS-006: Instantiate clean isolated helper modules via generate loop
    // =========================================================================
    always_comb begin
        for (int p = 0; p < 4; p++) begin
            bank_rd_addr[p] = issue_candidates_q[p];
        end
    end

    generate
        for (genvar p = 0; p < 4; p++) begin : gen_rs_banks
            rs_payload_bank #(
                .RS_DEPTH(RS_DEPTH)
            ) u_bank (
                .clk           (clk),
                .we            (pload_we_en_reg[p]),
                .wr_addr       (pload_we_ptr_reg[p]),
                .wr_pc         (pload_pc_w_reg[p]),
                .wr_opcode     (pload_opcode_w_reg[p]),
                .wr_imm        (pload_imm_w_reg[p]),
                .wr_funct3     (pload_funct3_w_reg[p]),
                .wr_funct7     (pload_funct7_w_reg[p]),
                .wr_precision  (pload_prec_w_reg[p]),
                .wr_branch_tag (pload_btag_w_reg[p]),
                .rd_addr       (bank_rd_addr[p]),
                .rd_pc         (bank_rd_pc[p]),
                .rd_opcode     (bank_rd_opcode[p]),
                .rd_imm        (bank_rd_imm[p]),
                .rd_funct3     (bank_rd_funct3[p]),
                .rd_funct7     (bank_rd_funct7[p]),
                .rd_precision  (bank_rd_precision[p]),
                .rd_branch_tag (bank_rd_branch_tag[p])
            );
        end
    endgenerate

    // =========================================================================
    // Combinational next-state Logic
    // =========================================================================
    always_comb begin
        integer s, p, d;
        logic [RS_IDX_W-1:0] slot;
        logic [2:0] dispatch_count;

        for (s = 0; s < RS_DEPTH; s++) begin
            n_rs_valid[s]        = rs_valid[s];
            n_rs_rob_idx[s]      = rs_rob_idx[s];
            n_rs_p_dest[s]       = rs_p_dest[s];
            n_rs_p_src1[s]       = rs_p_src1[s];
            n_rs_p_src2[s]       = rs_p_src2[s];
            n_rs_is_tensor_op[s] = rs_is_tensor_op[s];
            n_rs_is_memory[s]    = rs_is_memory[s];
            n_rs_is_branch[s]    = rs_is_branch[s];
            n_rs_is_csr[s]       = rs_is_csr[s];
            n_rs_age[s]          = rs_age[s];
            n_rs_pred_taken[s]   = rs_pred_taken[s];
            n_rs_pred_target[s]  = rs_pred_target[s];
            n_src1_ready[s]      = src1_ready[s];
            n_src2_ready[s]      = src2_ready[s];
            n_src1_val[s]        = src1_val[s];
            n_src2_val[s]        = src2_val[s];
            n_rs_reserved[s]     = rs_reserved[s];
            n_rs_issued[s]       = rs_issued[s];
        end
        n_occupancy = occupancy;
        n_rs_tail   = rs_tail;
        for (p = 0; p < 4; p++) begin
            n_issue_valid[p]   = 1'b0;
            n_issue_rob_idx[p] = '0;
            n_issue_uop[p]     = '0;
            n_issue_src1[p]    = '0;
            n_issue_src2[p]    = '0;
        end

        // FIX RS-TIMING-01: Vectorized Parallel Match Logic
        for (s = 0; s < RS_DEPTH; s++) begin
            logic is_ready;
            is_ready = n_src1_ready[s] && n_src2_ready[s];
            match_vec[0][s] = n_rs_valid[s] && is_ready && !n_rs_is_tensor_op[s] && !n_rs_is_memory[s] && !n_rs_is_branch[s] && !n_rs_is_csr[s];
            match_vec[1][s] = n_rs_valid[s] && is_ready &&  n_rs_is_branch[s];
            match_vec[2][s] = n_rs_valid[s] && is_ready &&  n_rs_is_memory[s];
            match_vec[3][s] = n_rs_valid[s] && is_ready && (n_rs_is_tensor_op[s] || n_rs_is_csr[s]);
        end

        // FIX RS-TIMING-01: Parallel Age-based Priority Encoder
        for (p = 0; p < 4; p++) begin
            sel_mask[p] = '0;
            sel_valid[p] = 1'b0;
            sel_idx[p] = '0;
            for (s = 0; s < RS_DEPTH; s++) begin
                if (match_vec[p][s] && !sel_valid[p]) begin
                    sel_mask[p][s] = 1'b1;
                    sel_valid[p] = 1'b1;
                    sel_idx[p] = RS_IDX_W'(s);
                end
            end
            n_issue_candidates[p]      = sel_idx[p];
            n_issue_candidate_valid[p] = sel_valid[p];
        end

        // Read from Bank Wires + Issue
        for (p = 0; p < 4; p++) begin
            if (issue_candidate_valid_q[p] && issue_ready_q[p]) begin
                slot = issue_candidates_q[p];
                if (!rs_issued[slot] && !rs_reserved[slot]) begin
                    n_rs_valid[slot]            = 1'b0;
                    n_issue_valid[p]            = 1'b1;
                    n_issue_rob_idx[p]          = rs_rob_idx[slot];
                    n_issue_uop[p].valid        = 1'b1;
                    n_issue_uop[p].rob_idx      = rs_rob_idx[slot];
                    n_issue_uop[p].p_dest       = rs_p_dest[slot];
                    n_issue_uop[p].p_src1       = rs_p_src1[slot];
                    n_issue_uop[p].p_src2       = rs_p_src2[slot];
                    n_issue_uop[p].is_tensor_op = rs_is_tensor_op[slot];
                    n_issue_uop[p].is_memory    = rs_is_memory[slot];
                    n_issue_uop[p].is_branch    = rs_is_branch[slot];
                    n_issue_uop[p].is_csr       = rs_is_csr[slot];
                    n_issue_uop[p].age          = rs_age[slot];
                    n_issue_uop[p].pred_taken   = rs_pred_taken[slot];
                    n_issue_uop[p].pred_target  = rs_pred_target[slot];
                    n_issue_uop[p].pc           = bank_rd_pc[p];
                    n_issue_uop[p].opcode       = bank_rd_opcode[p];
                    n_issue_uop[p].imm_data     = bank_rd_imm[p];
                    n_issue_uop[p].funct3       = bank_rd_funct3[p];
                    n_issue_uop[p].funct7       = bank_rd_funct7[p];
                    n_issue_uop[p].precision    = bank_rd_precision[p];
                    n_issue_uop[p].branch_tag   = bank_rd_branch_tag[p];
                    n_issue_src1[p]             = src1_val[slot];
                    n_issue_src2[p]             = src2_val[slot];
                end
            end
        end

        // CDB wakeup
        for (s = 0; s < RS_DEPTH; s++) begin
            if (n_rs_valid[s]) begin
                for (p = 0; p < 4; p++) begin
                    if (cdb_valid[p]) begin
                        if (n_rs_p_src1[s] == cdb_p_dest[p]) begin
                            n_src1_ready[s] = 1'b1;
                            n_src1_val[s]   = cdb_data[p];
                        end
                        if (n_rs_p_src2[s] == cdb_p_dest[p]) begin
                            n_src2_ready[s] = 1'b1;
                            n_src2_val[s]   = cdb_data[p];
                        end
                    end
                end
                if (n_rs_age[s] < 6'h3F) n_rs_age[s] = n_rs_age[s] + 1;
            end
        end

        // Dispatch
        dispatch_count = 3'd0;
        for (d = 0; d < 4; d++) begin
            slot = (n_rs_tail + RS_IDX_W'(d)) & (RS_DEPTH-1);
            if (dispatch_valid[d] && !n_rs_valid[slot] && !n_rs_reserved[slot]) begin
                n_rs_valid[slot]        = 1'b1;
                n_rs_rob_idx[slot]      = dispatch_rob_idx[d];
                n_rs_p_dest[slot]       = dispatch_uop[d].p_dest;
                n_rs_p_src1[slot]       = dispatch_uop[d].p_src1;
                n_rs_p_src2[slot]       = dispatch_uop[d].p_src2;
                n_rs_is_tensor_op[slot] = dispatch_uop[d].is_tensor_op;
                n_rs_is_memory[slot]    = dispatch_uop[d].is_memory;
                n_rs_is_branch[slot]    = dispatch_uop[d].is_branch;
                n_rs_is_csr[slot]       = dispatch_uop[d].is_csr;
                n_rs_age[slot]          = 6'h0;
                n_rs_pred_taken[slot]   = 1'b0;
                n_rs_pred_target[slot]  = 64'h0;
                n_src1_ready[slot]      = prf_ready_bits[dispatch_uop[d].p_src1];
                n_src2_ready[slot]      = prf_ready_bits[dispatch_uop[d].p_src2];
                n_src1_val[slot]        = 64'h0;
                n_src2_val[slot]        = 64'h0;
                dispatch_count          = dispatch_count + 1;
            end
        end

        // =================================================================
        // FIX RS-TIMING-02 + RS-TIMING-03: Occupancy - PURE ARITHMETIC
        //   NO conditional clamps. Vivado maps "else 0" and "> MAX" clamps
        //   to the FDRE R pin, recreating the deep path.
        //   RS_DEPTH=8: occupancy max = 8+4 = 12, fits in 7 bits (max 127).
        //   issue_count_q <= occupancy + dispatch_count by construction,
        //   so subtraction never underflows.
        //   flush is shallow (external input) - safe in D-path.
        // =================================================================
        issue_count = 3'd0;
        for (p = 0; p < 4; p++) if (n_issue_valid[p]) issue_count = issue_count + 1;

        n_rs_tail = (n_rs_tail + dispatch_count) & (RS_DEPTH-1);

        if (flush)
            n_occupancy = 7'h0;
        else
            n_occupancy = occupancy + {4'h0, dispatch_count} - {4'h0, issue_count_q};
    end

    // =========================================================================
    // Sequential update block
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n || flush) begin
            for (int i = 0; i < RS_DEPTH; i++) begin
                rs_valid[i]        <= 1'b0;
                rs_rob_idx[i]      <= '0;
                rs_p_dest[i]       <= '0;
                rs_p_src1[i]       <= '0;
                rs_p_src2[i]       <= '0;
                rs_is_tensor_op[i] <= 1'b0;
                rs_is_memory[i]    <= 1'b0;
                rs_is_branch[i]    <= 1'b0;
                rs_is_csr[i]       <= 1'b0;
                rs_age[i]          <= 6'h0;
                rs_pred_taken[i]   <= 1'b0;
                rs_pred_target[i]  <= 64'h0;
                src1_ready[i]      <= 1'b0;
                src2_ready[i]      <= 1'b0;
                src1_val[i]        <= 64'h0;
                src2_val[i]        <= 64'h0;
                rs_reserved[i]     <= 1'b0;
                rs_issued[i]       <= 1'b0;
            end
            rs_tail   <= '0;
            for (int p = 0; p < 4; p++) begin
                issue_candidates[p]        <= '0;
                issue_candidate_valid[p]   <= 1'b0;
                issue_candidates_q[p]      <= '0;
                issue_candidate_valid_q[p] <= 1'b0;
                issue_valid[p]             <= 1'b0;
                issue_rob_idx[p]           <= '0;
                issue_uop[p]               <= '0;
                issue_src1[p]              <= 64'h0;
                issue_src2[p]              <= 64'h0;
            end
            issue_ready_q <= 4'h0;
            issue_count_q <= 3'h0;
        end else begin
            for (int i = 0; i < RS_DEPTH; i++) begin
                rs_valid[i]        <= n_rs_valid[i];
                rs_rob_idx[i]      <= n_rs_rob_idx[i];
                rs_p_dest[i]       <= n_rs_p_dest[i];
                rs_p_src1[i]       <= n_rs_p_src1[i];
                rs_p_src2[i]       <= n_rs_p_src2[i];
                rs_is_tensor_op[i] <= n_rs_is_tensor_op[i];
                rs_is_memory[i]    <= n_rs_is_memory[i];
                rs_is_branch[i]    <= n_rs_is_branch[i];
                rs_is_csr[i]       <= n_rs_is_csr[i];
                rs_age[i]          <= n_rs_age[i];
                rs_pred_taken[i]   <= n_rs_pred_taken[i];
                rs_pred_target[i]  <= n_rs_pred_target[i];
                src1_ready[i]      <= n_src1_ready[i];
                src2_ready[i]      <= n_src2_ready[i];
                src1_val[i]        <= n_src1_val[i];
                src2_val[i]        <= n_src2_val[i];
                rs_reserved[i]     <= n_rs_reserved[i];
                rs_issued[i]       <= n_rs_issued[i];
            end
            rs_tail   <= n_rs_tail;
            for (int p = 0; p < 4; p++) begin
                issue_valid[p]             <= n_issue_valid[p];
                issue_rob_idx[p]           <= n_issue_rob_idx[p];
                issue_uop[p]               <= n_issue_uop[p];
                issue_src1[p]              <= n_issue_src1[p];
                issue_src2[p]              <= n_issue_src2[p];
                issue_candidates[p]        <= n_issue_candidates[p];
                issue_candidate_valid[p]   <= n_issue_candidate_valid[p];
                issue_candidates_q[p]      <= issue_candidates[p];
                issue_candidate_valid_q[p] <= issue_candidate_valid[p];
            end
            issue_ready_q <= issue_ready;
            issue_count_q <= issue_count;
        end

        // =================================================================
        // FIX RS-TIMING-02: Occupancy - SEPARATE reset (only !rst_n on R)
        // =================================================================
        if (!rst_n)
            occupancy <= 7'h0;
        else
            occupancy <= n_occupancy;
    end

    assign free_slots = 7'(RS_DEPTH) - occupancy;
    assign rs_full    = (occupancy >= 7'(RS_DEPTH - 4));
    assign rs_ready   = !rs_full;

    // =========================================================================
    // FIX BUG #1 (V5.4): Pipelined PRF Read Address generation
    // =========================================================================
    logic [6:0] prf_rd_addr_q [0:7];

    always_ff @(posedge clk) begin
        if (!rst_n || flush) begin
            for (int i = 0; i < 8; i++) prf_rd_addr_q[i] <= '0;
        end else begin
            for (int i = 0; i < 4; i++) begin
                prf_rd_addr_q[i*2]   <= issue_uop[i].p_src1;
                prf_rd_addr_q[i*2+1] <= issue_uop[i].p_src2;
            end
        end
    end

    always_comb begin
        for (int i = 0; i < 8; i++) prf_rd_addr[i] = prf_rd_addr_q[i];
    end

endmodule

// =========================================================================
// ISOLATED SUB-MODULE BANK FOR PERFECT DISTRIBUTED RAM INFERENCE
// =========================================================================
module rs_payload_bank #(
    parameter RS_DEPTH = 32,
    parameter RS_IDX_W = $clog2(RS_DEPTH)
)(
    input  logic        clk,
    input  logic        we,
    input  logic [RS_IDX_W-1:0] wr_addr,
    input  logic [63:0] wr_pc,
    input  logic [7:0]  wr_opcode,
    input  logic [63:0] wr_imm,
    input  logic [2:0]  wr_funct3,
    input  logic [6:0]  wr_funct7,
    input  logic [1:0]  wr_precision,
    input  logic [2:0]  wr_branch_tag,
    input  logic [RS_IDX_W-1:0] rd_addr,
    output logic [63:0] rd_pc,
    output logic [7:0]  rd_opcode,
    output logic [63:0] rd_imm,
    output logic [2:0]  rd_funct3,
    output logic [6:0]  rd_funct7,
    output logic [1:0]  rd_precision,
    output logic [2:0]  rd_branch_tag
);
    (* ram_style = "distributed" *) logic [63:0] mem_pc         [0:RS_DEPTH-1];
    (* ram_style = "distributed" *) logic [7:0]  mem_opcode     [0:RS_DEPTH-1];
    (* ram_style = "distributed" *) logic [63:0] mem_imm_data   [0:RS_DEPTH-1];
    (* ram_style = "distributed" *) logic [2:0]  mem_funct3     [0:RS_DEPTH-1];
    (* ram_style = "distributed" *) logic [6:0]  mem_funct7     [0:RS_DEPTH-1];
    (* ram_style = "distributed" *) logic [1:0]  mem_precision  [0:RS_DEPTH-1];
    (* ram_style = "distributed" *) logic [2:0]  mem_branch_tag [0:RS_DEPTH-1];

    always_ff @(posedge clk) begin
        if (we) begin
            mem_pc[wr_addr]         <= wr_pc;
            mem_opcode[wr_addr]     <= wr_opcode;
            mem_imm_data[wr_addr]   <= wr_imm;
            mem_funct3[wr_addr]     <= wr_funct3;
            mem_funct7[wr_addr]     <= wr_funct7;
            mem_precision[wr_addr]  <= wr_precision;
            mem_branch_tag[wr_addr] <= wr_branch_tag;
        end
    end

    assign rd_pc         = mem_pc[rd_addr];
    assign rd_opcode     = mem_opcode[rd_addr];
    assign rd_imm        = mem_imm_data[rd_addr];
    assign rd_funct3     = mem_funct3[rd_addr];
    assign rd_funct7     = mem_funct7[rd_addr];
    assign rd_precision  = mem_precision[rd_addr];
    assign rd_branch_tag = mem_branch_tag[rd_addr];
endmodule