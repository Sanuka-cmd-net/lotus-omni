`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:       Lotus Omni (Fabless AI Semiconductor)
// Engineer:      Sanuka Nethmira Amarasekara
// Module Name:   lotus_pmu - V2.0
// FIXED: OPT-001 - Division replaced with shift-based approximation
//////////////////////////////////////////////////////////////////////////////////

module lotus_pmu import lotus_pkg::*; (
    input  logic clk,
    input  logic rst_n,

    input  logic        ev_cycle,
    input  logic        ev_instr_commit,
    input  logic [2:0]  ev_commit_count,
    input  logic        ev_l1d_hit,
    input  logic        ev_l1d_miss,
    input  logic        ev_l2_hit,
    input  logic        ev_l2_miss,
    input  logic        ev_branch_pred,
    input  logic        ev_branch_mispredict,
    input  logic        ev_fetch_stall,
    input  logic        ev_rob_full_stall,
    input  logic        ev_rs_full_stall,
    input  logic        ev_tensor_active,
    input  logic        ev_sparsity_skip,

    input  logic [11:0] csr_addr,
    input  logic        csr_rd_en,
    output logic [63:0] csr_rd_data,
    input  logic        csr_wr_en,
    input  logic [63:0] csr_wr_data
);

    logic [63:0] cnt_cycles;
    logic [63:0] cnt_instrs;
    logic [63:0] cnt_l1d_hits;
    logic [63:0] cnt_l1d_misses;
    logic [63:0] cnt_l2_hits;
    logic [63:0] cnt_l2_misses;
    logic [63:0] cnt_branch_preds;
    logic [63:0] cnt_branch_mispreds;
    logic [63:0] cnt_fetch_stalls;
    logic [63:0] cnt_rob_stalls;
    logic [63:0] cnt_rs_stalls;
    logic [63:0] cnt_tensor_cycles;
    logic [63:0] cnt_sparsity_skips;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_cycles          <= '0;
            cnt_instrs          <= '0;
            cnt_l1d_hits        <= '0;
            cnt_l1d_misses      <= '0;
            cnt_l2_hits         <= '0;
            cnt_l2_misses       <= '0;
            cnt_branch_preds    <= '0;
            cnt_branch_mispreds <= '0;
            cnt_fetch_stalls    <= '0;
            cnt_rob_stalls      <= '0;
            cnt_rs_stalls       <= '0;
            cnt_tensor_cycles   <= '0;
            cnt_sparsity_skips  <= '0;
        end else begin
            // HIGH-016 FIX: Add overflow protection for counters
            cnt_cycles <= (cnt_cycles == 64'hFFFFFFFFFFFFFFFF) ? cnt_cycles : cnt_cycles + 1;
            cnt_instrs <= (cnt_instrs >= 64'hFFFFFFFFFFFFFFFF - ev_commit_count) ? 64'hFFFFFFFFFFFFFFFF : cnt_instrs + ev_commit_count;
            if (ev_l1d_hit)         cnt_l1d_hits        <= (cnt_l1d_hits == 64'hFFFFFFFFFFFFFFFF) ? cnt_l1d_hits : cnt_l1d_hits + 1;
            if (ev_l1d_miss)        cnt_l1d_misses      <= (cnt_l1d_misses == 64'hFFFFFFFFFFFFFFFF) ? cnt_l1d_misses : cnt_l1d_misses + 1;
            if (ev_l2_hit)          cnt_l2_hits         <= (cnt_l2_hits == 64'hFFFFFFFFFFFFFFFF) ? cnt_l2_hits : cnt_l2_hits + 1;
            if (ev_l2_miss)         cnt_l2_misses       <= (cnt_l2_misses == 64'hFFFFFFFFFFFFFFFF) ? cnt_l2_misses : cnt_l2_misses + 1;
            if (ev_branch_pred)     cnt_branch_preds    <= (cnt_branch_preds == 64'hFFFFFFFFFFFFFFFF) ? cnt_branch_preds : cnt_branch_preds + 1;
            if (ev_branch_mispredict) cnt_branch_mispreds <= (cnt_branch_mispreds == 64'hFFFFFFFFFFFFFFFF) ? cnt_branch_mispreds : cnt_branch_mispreds + 1;
            if (ev_fetch_stall)     cnt_fetch_stalls    <= (cnt_fetch_stalls == 64'hFFFFFFFFFFFFFFFF) ? cnt_fetch_stalls : cnt_fetch_stalls + 1;
            if (ev_rob_full_stall)  cnt_rob_stalls      <= (cnt_rob_stalls == 64'hFFFFFFFFFFFFFFFF) ? cnt_rob_stalls : cnt_rob_stalls + 1;
            if (ev_rs_full_stall)   cnt_rs_stalls       <= (cnt_rs_stalls == 64'hFFFFFFFFFFFFFFFF) ? cnt_rs_stalls : cnt_rs_stalls + 1;
            if (ev_tensor_active)   cnt_tensor_cycles   <= (cnt_tensor_cycles == 64'hFFFFFFFFFFFFFFFF) ? cnt_tensor_cycles : cnt_tensor_cycles + 1;
            if (ev_sparsity_skip)   cnt_sparsity_skips  <= (cnt_sparsity_skips == 64'hFFFFFFFFFFFFFFFF) ? cnt_sparsity_skips : cnt_sparsity_skips + 1;

            if (csr_wr_en) begin
                case (csr_addr)
                    12'hB00: cnt_cycles          <= csr_wr_data;
                    12'hB02: cnt_instrs          <= csr_wr_data;
                    12'hB03: cnt_l1d_hits        <= csr_wr_data;
                    12'hB04: cnt_l1d_misses      <= csr_wr_data;
                    12'hB05: cnt_l2_hits         <= csr_wr_data;
                    12'hB06: cnt_l2_misses       <= csr_wr_data;
                    12'hB07: cnt_branch_preds    <= csr_wr_data;
                    12'hB08: cnt_branch_mispreds <= csr_wr_data;
                    default: ;
                endcase
            end
        end
    end

    always_comb begin
        csr_rd_data = 64'h0;
        if (csr_rd_en) begin
            case (csr_addr)
                12'hB00: csr_rd_data = cnt_cycles;
                12'hB02: csr_rd_data = cnt_instrs;
                12'hB03: csr_rd_data = cnt_l1d_hits;
                12'hB04: csr_rd_data = cnt_l1d_misses;
                12'hB05: csr_rd_data = cnt_l2_hits;
                12'hB06: csr_rd_data = cnt_l2_misses;
                12'hB07: csr_rd_data = cnt_branch_preds;
                12'hB08: csr_rd_data = cnt_branch_mispreds;
                12'hB09: csr_rd_data = cnt_fetch_stalls;
                12'hB0A: csr_rd_data = cnt_rob_stalls;
                12'hB0B: csr_rd_data = cnt_rs_stalls;
                12'hB0C: csr_rd_data = cnt_tensor_cycles;
                12'hB0D: csr_rd_data = cnt_sparsity_skips;
                // NEW: Raw counters for software to compute metrics
                12'hC00: csr_rd_data = cnt_cycles;          // Total cycles (raw)
                12'hC01: csr_rd_data = cnt_instrs;          // Total instructions committed (raw)
                12'hC02: csr_rd_data = cnt_branch_preds;    // Total branches (raw)
                12'hC03: csr_rd_data = cnt_branch_mispreds; // Total mispredictions (raw)
                12'hC04: csr_rd_data = cnt_l1d_hits;        // L1D hits (raw)
                12'hC05: csr_rd_data = cnt_l1d_misses;      // L1D misses (raw)
                default:  csr_rd_data = 64'hDEAD_BEEF;
            endcase
        end
    end

endmodule