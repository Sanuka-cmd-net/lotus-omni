// =========================================
// File Name: lotus_omni_core_top_v2.sv
// =========================================
`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// lotus_omni_core_top_v2 - V11.1 LSQ DEADLOCK FIX
// Engineer:     Sanuka Nethmira Amarasekara (Lotus Omni)
// Target:       Xilinx Artix-7 xc7a200t
//
// V11.1 (THIS VERSION):
//   • FIXED CRITICAL LSQ DEADLOCK BUG: Restricted SQ allocation strictly to 
//     STORE instructions. Loads now bypass SQ allocation, preventing them 
//     from polluting the Store Queue and blocking the drain logic.
//
// V11.0: FIXED CRITICAL OPERAND FORWARDING BUG (AGU addr=0 fix)
// V10.9: FIXED SIMULATION X-STATE BUG (BUFG removed for simulation)
// V10.8: FIXED AGU/LSQ DEADLOCK (Removed erroneous 1-cycle delay)
// V10.7: AGU PIPELINE DEADLOCK FIX (Initial attempt)
// V10.6: FIXED FATAL TRUNCATION BUG (Unified flow gate buses)
//////////////////////////////////////////////////////////////////////////////////

module lotus_omni_core_top_v2 #(
    parameter DATA_WIDTH        = 64,
    parameter ADDR_WIDTH        = 64,
    parameter CORD_WIDTH        = 4,
    parameter ROB_ENTRIES       = 32,
    parameter PRF_ENTRIES       = 128,
    parameter RS_DEPTH          = 8,
    parameter LSU_FIFO_DEPTH    = 4,
    parameter DRAM_FIFO_DEPTH   = 4,
    parameter NOC_FIFO_DEPTH    = 4,
    parameter TENSOR_FIFO_DEPTH = 4
)(
    input  logic clk,
    input  logic rst_n,

    input  logic [31:0] fetch_word_in,
    input  logic [3:0]  fetch_word_idx,
    input  logic        fetch_word_valid,
    input  logic [63:0] fetch_pc_in,
    input  logic        fetch_bundle_commit,

    output logic        fetch_ready,

    output logic [63:0] noc_tx_data,
    output logic [1:0]  noc_tx_flit_type,
    output logic [2:0]  noc_tx_port_id,
    output logic        noc_tx_valid,
    input  logic        noc_tx_ready,

    input  logic [63:0] noc_rx_data,
    input  logic [1:0]  noc_rx_flit_type,
    input  logic [2:0]  noc_rx_port_id,
    input  logic [3:0]  noc_rx_dest_x,
    input  logic [3:0]  noc_rx_dest_y,
    input  logic        noc_rx_valid,
    output logic        noc_rx_ready,

    output logic          dram_req_valid,
    output logic          dram_req_rw,
    output logic [63:0]   dram_req_addr,
    output logic [1023:0] dram_req_data,
    input  logic          dram_req_ready,
    input  logic          dram_resp_valid,
    input  logic [1023:0] dram_resp_data,

    output logic [63:0] perf_ipc,
    output logic        core_active,
    output logic        exception_out,

    input  logic        flow_gate_enable,
    input  logic [7:0]  global_throttle_limit,
    output logic [7:0]  flow_gate_status,
    output logic        flow_gate_throttled
);

    import lotus_pkg::*;

    // =========================================================================
    // FIX TOP-TIMING-01 + V10.9 SIMULATION X-STATE FIX
    // BUFG causes 'X' states in XSim. Use direct connection for simulation.
    // Synthesis will automatically infer BUFG for high-fanout nets.
    // =========================================================================
    (* MAX_FANOUT = 300 *) logic rst_n_g;
    assign rst_n_g = rst_n;

    // =========================================================================
    // FLOW GATE STATUS
    // =========================================================================
    logic lsu_gate_stalled, dram_gate_stalled, noc_gate_stalled, tensor_gate_stalled;
    logic [7:0]  lsu_credit_count, dram_credit_count, noc_credit_count, tensor_credit_count;
    logic [2:0]  lsu_fifo_count, dram_fifo_count, noc_fifo_count, tensor_fifo_count;

    assign flow_gate_status    = {lsu_gate_stalled, lsu_fifo_count[2:0]};
    assign flow_gate_throttled = lsu_gate_stalled | dram_gate_stalled |
                                 noc_gate_stalled  | tensor_gate_stalled;

    // =========================================================================
    // CSR / EXCEPTION
    // =========================================================================
    logic exception_internal;
    logic csr_issue_valid;
    rs_entry_t csr_issue_uop;
    logic [63:0] csr_src1_data, csr_rdata_out, mtvec_from_csr, mepc_from_csr;
    logic [1:0]  precision_mode;
    logic sparsity_en_csr, tensor_en_csr, csr_illegal_out;

    // =========================================================================
    // FLUSH / EXCEPTION CONTROL
    // =========================================================================
    logic        rob_exception_flush, rob_flush_comb;
    (* MAX_FANOUT = 300 *) logic rob_flush_reg;
    logic [63:0] rob_flush_target_pc, exception_pc_w, exception_cause_w;

    logic        ifu_req_valid;
    logic [63:0] ifu_req_pc;
    logic        ifu_req_ready, l1i_resp_valid, l1i_resp_hit;
    logic [511:0] l1i_resp_data;

    logic        l1i_mem_req_valid;
    logic [63:0] l1i_mem_req_addr;
    logic        l1i_mem_req_ready, l1i_mem_resp_valid;
    logic [511:0] l1i_mem_resp_data;

    fetch_packet_t ifu_dec_packet;
    logic          ifu_dec_valid, ifu_dec_ready;
    logic [63:0] tage_predicted_pc;
    logic        tage_taken, branch_update_valid;
    logic [63:0] branch_update_pc, branch_actual_target;
    logic        branch_actual_taken;
    logic [63:0] tage_perf_predictions, tage_perf_mispredicts;

    // NOC
    logic [4:1] ext_rx_valid_int, ext_rx_ready_int, ext_tx_valid_int, ext_tx_ready_int;
    logic [4:1][1:0]  ext_rx_flit_type_int, ext_tx_flit_type_int;
    logic [4:1][3:0]  ext_rx_dest_x_int, ext_rx_dest_y_int;
    logic [4:1][63:0] ext_rx_payload_int, ext_tx_payload_int;

    logic noc_local_out_valid;
    logic [1:0]  noc_local_out_flit;
    logic [63:0] noc_local_out_payload;
    logic [4:0]  router_rx_ready_out;
    logic [2:0]  tx_arb_ptr;

    logic [2:0]  commit_count_pmu;
    logic [63:0] cycle_count, commit_total;

    // =========================================================================
    // DECODER -> RENAMER
    // =========================================================================
    uop_t       dec_uops [0:3];
    logic [3:0] dec_uop_valid;
    logic       dec_dispatch_ready;

    // =========================================================================
    // RENAMER
    // =========================================================================
    logic         renamer_ready;
    renamed_uop_t ren_uops [0:3];
    logic [3:0]   ren_uop_valid;
    logic [6:0]   commit_p_old_dest [0:3];
    logic [3:0]   commit_valid_renamer;
    logic [7:0]   free_list_count;
    logic         save_checkpoint;
    logic [2:0]   save_branch_tag;
    logic         flush_branch_valid;
    logic [2:0]   flush_branch_tag;

    // =========================================================================
    // RESERVATION STATION
    // =========================================================================
    logic          rs_ready_out;
    logic [3:0]    rs_issue_valid;
    logic [6:0]    rs_issue_rob_idx [0:3];
    rs_entry_t     rs_issue_uops    [0:3];
    logic [63:0]   rs_issue_src1    [0:3];
    logic [63:0]   rs_issue_src2    [0:3];
    logic [3:0]    rs_issue_ready;
    logic [2:0]    rs_dispatch_branch_tag [0:3];

    logic [3:0]    rs_cdb_valid;
    logic [6:0]    rs_cdb_p_dest [0:3];
    logic [63:0]   rs_cdb_data   [0:3];

    // =========================================================================
    // FIX TOP-IFU & Bug #10
    // =========================================================================
    logic rob_ready;
    assign dec_dispatch_ready = renamer_ready && rs_ready_out && rob_ready;

    // =========================================================================
    // PRF
    // =========================================================================
    logic [6:0]  prf_rd_addr   [0:7];
    logic [6:0]  prf_rd_addr_q [0:7];
    logic [63:0] prf_rd_data   [0:7];
    logic [6:0]  prf_wr_addr   [0:3];
    logic [63:0] prf_wr_data   [0:3];
    logic [3:0]  prf_wr_en;

    logic [7:0][6:0]  prf_rd_addr_p;
    logic [7:0][63:0] prf_rd_data_p;
    logic [3:0][6:0]  prf_wr_addr_p;
    logic [3:0][63:0] prf_wr_data_p;
    logic [3:0][6:0]  prf_wr_rob_p;
    logic [6:0]       rs_issue_rob_idx_q [0:3];

    logic        prf_commit_valid;
    logic [6:0]  prf_commit_addr;
    logic        prf_stall;

    always_comb begin
        for (int i = 0; i < 8; i++) prf_rd_addr_p[i] = prf_rd_addr[i];
        for (int i = 0; i < 4; i++) begin
            prf_wr_addr_p[i] = prf_wr_addr[i];
            prf_wr_data_p[i] = prf_wr_data[i];
            prf_wr_rob_p[i]  = rs_issue_rob_idx_q[i];
        end
    end

    always_comb begin
        for (int i = 0; i < 8; i++) prf_rd_data[i] = prf_rd_data_p[i];
    end

    always_ff @(posedge clk) begin
        if (!rst_n_g) for (int i = 0; i < 8; i++) prf_rd_addr_q[i] <= 7'h0;
        else begin
            prf_rd_addr_q[0] <= rs_issue_uops[0].p_src1;
            prf_rd_addr_q[1] <= rs_issue_uops[0].p_src2;
            prf_rd_addr_q[2] <= rs_issue_uops[1].p_src1;
            prf_rd_addr_q[3] <= rs_issue_uops[1].p_src2;
            prf_rd_addr_q[4] <= rs_issue_uops[2].p_src1;
            prf_rd_addr_q[5] <= rs_issue_uops[2].p_src2;
            prf_rd_addr_q[6] <= rs_issue_uops[3].p_src1;
            prf_rd_addr_q[7] <= rs_issue_uops[3].p_src2;
        end
    end

    // =========================================================================
    // FIX Bug #5 (CORE-PRFREADY)
    // =========================================================================
    logic [127:0] prf_ready_bits;
    always_ff @(posedge clk) begin
        if (!rst_n_g) begin
            prf_ready_bits <= {128{1'b1}};
        end else begin
            if (prf_commit_valid && prf_commit_addr != 7'h0)
                prf_ready_bits[prf_commit_addr] <= 1'b1;
            for (int i = 0; i < 4; i++) begin
                if (ren_uop_valid[i] && ren_uops[i].p_dest != 7'h0)
                    prf_ready_bits[ren_uops[i].p_dest] <= 1'b0;
            end
        end
    end

    // =========================================================================
    // CDB
    // =========================================================================
    logic        alu_cdb_valid,   branch_cdb_valid,   load_cdb_valid,   csr_cdb_valid;
    logic [6:0]  alu_cdb_p_dest,  branch_cdb_p_dest,  load_cdb_p_dest,  csr_cdb_p_dest;
    logic [63:0] alu_cdb_data,    branch_cdb_data,    load_cdb_data,    csr_cdb_data;

    logic        branch_resolved,  branch_mispredicted;
    logic        branch_correct_pc_valid;
    logic [63:0] branch_correct_pc;
    logic [2:0]  branch_tag_out;
    logic        branch_perf_mispredict;

    logic [6:0]  csr_issue_rob_idx;
    logic [63:0] illegal_csr_cause = 64'h2;

    // =========================================================================
    // TENSOR ENGINE & MEMORY ARBITER INTERNAL WIRES
    // =========================================================================
    logic        arb_to_l1d_req_valid, arb_to_l1d_req_rw;
    logic [63:0] arb_to_l1d_req_addr, arb_to_l1d_req_data;
    logic [7:0]  arb_to_l1d_req_wmask;
    logic        l1d_to_arb_req_ready;

    logic        ten_mem_req_valid, arb_to_ten_mem_ready;
    logic [63:0] ten_mem_req_addr;
    logic        arb_to_ten_resp_valid;
    logic [511:0] arb_to_ten_resp_data;

    logic        ten_cdb_valid;
    logic [6:0]  ten_cdb_p_dest;
    logic [63:0] ten_cdb_data;
    logic        engine_ready;
    logic        tensor_array_enable;

    // =========================================================================
    // V9.0 TENSOR DATAFLOW FIX: clear_acc wiring
    // =========================================================================
    logic        tensor_feed_first;
    logic        tensor_clear;
    assign tensor_clear = rob_flush_reg | tensor_feed_first;

    // =========================================================================
    // FIX Bug #4 (CORE-CDBMUX)
    // =========================================================================
    always_comb begin
        rs_cdb_valid[0]  = alu_cdb_valid;    rs_cdb_p_dest[0] = alu_cdb_p_dest;    rs_cdb_data[0] = alu_cdb_data;
        rs_cdb_valid[1]  = branch_cdb_valid; rs_cdb_p_dest[1] = branch_cdb_p_dest; rs_cdb_data[1] = branch_cdb_data;
        rs_cdb_valid[2]  = load_cdb_valid;   rs_cdb_p_dest[2] = load_cdb_p_dest;   rs_cdb_data[2] = load_cdb_data;
        rs_cdb_valid[3]  = csr_cdb_valid | ten_cdb_valid;
        rs_cdb_p_dest[3] = csr_cdb_valid ? csr_cdb_p_dest : ten_cdb_p_dest;
        rs_cdb_data[3]   = csr_cdb_valid ? csr_cdb_data   : ten_cdb_data;
    end

    always_ff @(posedge clk) begin
        if (!rst_n_g) for (int i = 0; i < 4; i++) rs_issue_rob_idx_q[i] <= 7'h0;
        else        for (int i = 0; i < 4; i++) rs_issue_rob_idx_q[i] <= rs_issue_rob_idx[i];
    end

    always_comb begin
        prf_wr_addr[0]=alu_cdb_p_dest;    prf_wr_data[0]=alu_cdb_data;    prf_wr_en[0]=alu_cdb_valid;
        prf_wr_addr[1]=branch_cdb_p_dest; prf_wr_data[1]=branch_cdb_data; prf_wr_en[1]=branch_cdb_valid;
        prf_wr_addr[2]=load_cdb_p_dest;   prf_wr_data[2]=load_cdb_data;   prf_wr_en[2]=load_cdb_valid;
        prf_wr_addr[3]=csr_cdb_valid ? csr_cdb_p_dest : ten_cdb_p_dest;
        prf_wr_data[3]=csr_cdb_valid ? csr_cdb_data   : ten_cdb_data;
        prf_wr_en[3]  =csr_cdb_valid | ten_cdb_valid;
    end

    // =========================================================================
    // ROB CDB (Variables declared here, assignment logic moved to bottom!)
    // =========================================================================
    logic [3:0]  rob_cdb_valid;
    logic [6:0]  rob_cdb_rob_idx [0:3];
    logic [63:0] rob_cdb_data    [0:3];
    logic [3:0]  rob_cdb_exception;
    logic [63:0] rob_cdb_exc_cause [0:3];

    logic        agu_misalign;
    logic [63:0] agu_misalign_addr;

    logic        agu_completes;

    // =========================================================================
    // === TIMING FIX ROB-TIMING-01: Pipeline CDB→ROB path ===
    // =========================================================================
    logic [3:0]  rob_cdb_valid_q;
    logic [6:0]  rob_cdb_rob_idx_q [0:3];
    logic [63:0] rob_cdb_data_q    [0:3];
    logic [3:0]  rob_cdb_exception_q;
    logic [63:0] rob_cdb_exc_cause_q [0:3];

    always_ff @(posedge clk) begin
        if (!rst_n_g) begin
            rob_cdb_valid_q     <= '0;
            rob_cdb_exception_q <= '0;
            for (int i = 0; i < 4; i++) begin
                rob_cdb_rob_idx_q[i]   <= '0;
                rob_cdb_data_q[i]      <= '0;
                rob_cdb_exc_cause_q[i] <= '0;
            end
        end else begin
            rob_cdb_valid_q     <= rob_cdb_valid;
            rob_cdb_exception_q <= rob_cdb_exception;
            for (int i = 0; i < 4; i++) begin
                rob_cdb_rob_idx_q[i]   <= rob_cdb_rob_idx[i];
                rob_cdb_data_q[i]      <= rob_cdb_data[i];
                rob_cdb_exc_cause_q[i] <= rob_cdb_exc_cause[i];
            end
        end
    end

    // =========================================================================
    // ROB SIGNALS
    // =========================================================================
    logic [3:0]       rob_dispatch_valid;
    renamed_uop_t     rob_dispatch_uop [0:3];
    logic [6:0]       rob_alloc_idx [0:3];
    logic [3:0]       rob_commit_valid;
    logic [6:0]       rob_commit_p_dest      [0:3];
    logic [6:0]       rob_commit_p_old_dest [0:3];
    logic [63:0]      rob_commit_data        [0:3];
    logic [3:0]       rob_commit_is_store;
    (* keep *) logic [4:0] rob_commit_lsq_idx [0:3];
    (* keep *) logic [6:0] rob_commit_rob_idx [0:3];

    logic             rob_flush_req;
    logic [63:0]      rob_flush_target;
    logic             rob_exception_valid;
    logic [63:0]      rob_exception_cause;
    logic [63:0]      rob_exception_pc;
    logic [7:0]       rob_occupancy;
    logic             rob_full, rob_empty;

    logic [3:0] commit_ack;
    assign commit_ack = 4'b1111;  // FIX Bug #1

    assign rob_flush_comb = branch_mispredicted | rob_exception_flush;

    always_ff @(posedge clk) begin
        if (!rst_n_g) rob_flush_reg <= 1'b0;
        else        rob_flush_reg <= rob_flush_comb;
    end

    logic [2:0] flush_branch_tag_reg;
    always_ff @(posedge clk) begin
        if (!rst_n_g) flush_branch_tag_reg <= 3'h0;
        else if (branch_mispredicted) flush_branch_tag_reg <= branch_tag_out;
    end

    assign rob_flush_target_pc = rob_flush_req ? rob_flush_target : branch_correct_pc;
    assign exception_pc_w      = rob_exception_pc;
    assign exception_cause_w   = rob_exception_cause;

    // =========================================================================
    // === TIMING FIX LSQ-TIMING-02: Commit pipeline register for LSQ ===
    // =========================================================================
    logic [3:0]  lsq_commit_valid_q;
    logic [3:0]  lsq_commit_is_store_q;
    logic [6:0]  lsq_commit_rob_idx_q [0:3];

    always_ff @(posedge clk or negedge rst_n_g) begin
        if (!rst_n_g) begin
            lsq_commit_valid_q    <= '0;
            lsq_commit_is_store_q <= '0;
            for (int i = 0; i < 4; i++) lsq_commit_rob_idx_q[i] <= '0;
        end else begin
            lsq_commit_valid_q    <= rob_commit_valid;
            lsq_commit_is_store_q <= rob_commit_is_store;
            for (int i = 0; i < 4; i++) lsq_commit_rob_idx_q[i] <= rob_commit_rob_idx[i];
        end
    end

    // =========================================================================
    // AGU / LSQ
    // =========================================================================
    logic        agu_valid, agu_is_store;
    logic [63:0] agu_addr, agu_data;
    logic [7:0]  agu_wmask;
    logic        load_fwd_valid, load_needs_cache;
    logic [63:0] load_fwd_data;
    logic [6:0]  agu_rob_idx_q;

    logic        lsq_l1d_req_valid, lsq_l1d_req_rw;
    logic [63:0] lsq_l1d_req_addr, lsq_l1d_req_data;
    logic [7:0]  lsq_l1d_req_wmask;
    logic        lsq_l1d_req_ready;

    always_ff @(posedge clk) begin
        if (!rst_n_g) agu_rob_idx_q <= 7'h0;
        else if (rs_issue_valid[2] && rs_issue_uops[2].is_memory)
            agu_rob_idx_q <= rs_issue_rob_idx[2];
    end

    logic        l1d_cpu_resp_valid, l1d_cpu_resp_hit;
    logic [511:0] l1d_cpu_resp_data;

    logic        l1d_mem_req_valid, l1d_mem_req_rw;
    logic [63:0] l1d_mem_req_addr;
    logic [7:0]  l1d_mem_req_wmask;
    logic        l1d_mem_req_ready, l1d_mem_resp_valid;
    logic [511:0] l1d_mem_resp_data, l2_l1d_resp_data;
    logic         l2_l1d_resp_valid;

    // =========================================================================
    // === TIMING FIX LSQ-TIMING-03: Pipeline load p_dest + offset + rob_idx ===
    // =========================================================================
    logic [6:0] load_pdest_q;
    logic [5:0] load_offset_q;
    logic [6:0] load_rob_idx_q;

    always_ff @(posedge clk) begin
        if (!rst_n_g) begin
            load_pdest_q   <= 7'h00;
            load_offset_q  <= 6'd0;
            load_rob_idx_q <= 7'h00;
        end else if (agu_valid && !agu_is_store) begin
            load_pdest_q   <= rs_issue_uops[2].p_dest;
            load_offset_q  <= agu_addr[5:0];      // V10.0: capture word offset
            load_rob_idx_q <= agu_rob_idx_q;
        end
    end

    // =========================================================================
    // LOAD RESPONSE STATE MACHINE
    // =========================================================================
    logic [6:0] pending_load_pdest;
    logic [5:0] pending_load_offset;
    logic [6:0] pending_load_rob_idx;
    logic       load_state;
    logic [6:0] load_cdb_rob_idx_out;

    always_ff @(posedge clk) begin
        if (!rst_n_g || rob_flush_reg) begin
            pending_load_pdest   <= 7'h00;
            pending_load_offset  <= 6'd0;
            pending_load_rob_idx <= 7'h00;
            load_state           <= 1'b0;
            load_cdb_valid       <= 1'b0;
            load_cdb_p_dest      <= 7'h00;
            load_cdb_data        <= 64'h0;
            load_cdb_rob_idx_out <= 7'h00;
        end else begin
            load_cdb_valid <= 1'b0;
            case (load_state)
                1'b0: begin
                    if (load_fwd_valid) begin
                        load_cdb_valid       <= 1'b1;
                        load_cdb_p_dest      <= load_pdest_q;
                        load_cdb_data        <= load_fwd_data;
                        load_cdb_rob_idx_out <= load_rob_idx_q;
                    end else if (load_needs_cache) begin
                        pending_load_pdest   <= load_pdest_q;
                        pending_load_offset  <= load_offset_q;
                        pending_load_rob_idx <= load_rob_idx_q;
                        load_state           <= 1'b1;
                    end
                end
                1'b1: begin
                    if (load_fwd_valid) begin
                        load_cdb_valid       <= 1'b1;
                        load_cdb_p_dest      <= pending_load_pdest;
                        load_cdb_data        <= load_fwd_data;
                        load_cdb_rob_idx_out <= pending_load_rob_idx;
                        load_state           <= 1'b0;
                    end else if (l1d_cpu_resp_valid) begin
                        load_cdb_valid       <= 1'b1;
                        load_cdb_p_dest      <= pending_load_pdest;
                        load_cdb_data        <= l1d_cpu_resp_data[{pending_load_offset[5:3],6'd0} +: 64];
                        load_cdb_rob_idx_out <= pending_load_rob_idx;
                        load_state           <= 1'b0;
                    end
                end
            endcase
        end
    end

    // =========================================================================
    // TENSOR CORE
    // =========================================================================
    logic [15:0]  tensor_bf16_a [0:7];
    logic [15:0]  tensor_bf16_b [0:7];
    logic signed [7:0]  tensor_int8_a [0:7];
    logic signed [7:0]  tensor_int8_b [0:7];
    logic [31:0]        tensor_bf16_results [0:7][0:7];
    logic signed [31:0] tensor_int8_out     [0:7][0:7];

    logic [127:0] tensor_weight_bf16;
    logic [127:0] tensor_input_bf16;
    logic [63:0]  tensor_weight_int8;
    logic [63:0]  tensor_input_int8;

    assign csr_cdb_valid  = csr_issue_valid;
    assign csr_cdb_p_dest = csr_issue_uop.p_dest;
    assign csr_cdb_data   = csr_rdata_out;

    always_comb begin
        csr_issue_rob_idx = 7'h0;
        if      (rs_issue_valid[0] && rs_issue_uops[0].is_csr) csr_issue_rob_idx = rs_issue_rob_idx[0];
        else if (rs_issue_valid[1] && rs_issue_uops[1].is_csr) csr_issue_rob_idx = rs_issue_rob_idx[1];
        else if (rs_issue_valid[2] && rs_issue_uops[2].is_csr) csr_issue_rob_idx = rs_issue_rob_idx[2];
        else if (rs_issue_valid[3] && rs_issue_uops[3].is_csr) csr_issue_rob_idx = rs_issue_rob_idx[3];
    end

    logic signed [7:0]  sparse_out_internal [0:31];
    logic [2:0]         meta_out_internal   [0:15];
    logic [7:0]         sparsity_packed_data [0:7];
    logic signed [7:0]  sparsity_dense_in   [0:63];
    logic [5:0]         sparsity_nz_count;

    logic               sparsity_in_valid       = 1'b0;
    logic               sparsity_to_tensor_valid;
    logic               tensor_array_busy;
    logic               sparsity_enable;

    assign sparsity_enable = sparsity_en_csr;

    genvar g;
    generate
        for (g = 0; g < 64; g++) begin : gen_dense_init
            assign sparsity_dense_in[g] = 8'h0;
        end
        for (g = 0; g < 8; g++) begin : gen_tensor_routing
            assign sparsity_packed_data[g] = sparse_out_internal[g];
            assign tensor_bf16_a[g] = sparsity_enable ?
                {sparsity_packed_data[g], 8'h00} : tensor_input_bf16[g*16 +: 16];
            assign tensor_bf16_b[g] = tensor_weight_bf16[g*16 +: 16];
            assign tensor_int8_a[g] = sparsity_enable ?
                sparsity_packed_data[g] : tensor_input_int8[g*8 +: 8];
            assign tensor_int8_b[g] = tensor_weight_int8[g*8 +: 8];
        end
    endgenerate

    // =========================================================================
    // SUBMODULE INSTANTIATIONS
    // =========================================================================
    lotus_sparsity_engine_v3 u_sparsity (
        .clk(clk), .rst_n(rst_n_g),
        .dense_in(sparsity_dense_in), .in_valid(sparsity_in_valid), .in_ready(),
        .sparse_out(sparse_out_internal), .meta_out(meta_out_internal),
        .nz_count_out(sparsity_nz_count), .out_valid(sparsity_to_tensor_valid),
        .out_ready(~tensor_array_busy)
    );

    lotus_bf16_systolic_array_8x8_v3 u_tensor_bf16 (
        .clk(clk), .rst_n(rst_n_g),
        .enable(tensor_array_enable & tensor_en_csr),
        .clear_acc(tensor_clear),
        .a_in(tensor_bf16_a), .b_in(tensor_bf16_b), .pe_results(tensor_bf16_results)
    );

    lotus_int8_systolic_array_8x8 u_tensor_int8 (
        .clk(clk), .rst_n(rst_n_g),
        .enable(tensor_array_enable & tensor_en_csr & ~precision_mode[0]),
        .clear_acc(tensor_clear),
        .a_in(tensor_int8_a), .b_in(tensor_int8_b), .pe_results(tensor_int8_out)
    );

    lotus_noc_router_masterpiece u_noc_router (
        .clk(clk), .rst_n(rst_n_g), .my_x(4'd1), .my_y(4'd1),
        .rx_valid({ext_rx_valid_int, 1'b0}),
        .rx_flit_type({ext_rx_flit_type_int, 2'b0}),
        .rx_dest_x({ext_rx_dest_x_int, 4'h0}),
        .rx_dest_y({ext_rx_dest_y_int, 4'h0}),
        .rx_payload({ext_rx_payload_int, 64'h0}),
        .rx_ready(router_rx_ready_out),
        .tx_valid(ext_tx_valid_int), .tx_flit_type(ext_tx_flit_type_int),
        .tx_payload(ext_tx_payload_int), .tx_ready(ext_tx_ready_int),
        .local_valid(noc_local_out_valid), .local_flit_type(noc_local_out_flit),
        .local_payload(noc_local_out_payload), .local_ready(1'b1)
    );

    assign noc_rx_ready = router_rx_ready_out[0];

    logic pf_req_valid_wire;
    logic [63:0] pf_req_addr_wire;

    lotus_prefetcher u_prefetcher (
        .clk(clk), .rst_n(rst_n_g),
        .access_valid(l1d_cpu_resp_valid & !l1d_cpu_resp_hit),
        .access_addr(agu_addr), .access_pc(rs_issue_uops[2].pc),
        .pf_req_valid(pf_req_valid_wire), .pf_req_addr(pf_req_addr_wire),
        .pf_req_ready(1'b1)
    );

    // =========================================================================
    // === TIMING FIX PMU-TIMING-01: Pipeline performance counter ===
    // =========================================================================
    always_comb begin
        commit_count_pmu = '0;
        for (int k = 0; k < 4; k++)
            if (rob_commit_valid[k]) commit_count_pmu = commit_count_pmu + 1;
    end

    logic [2:0] commit_count_pmu_q;
    always_ff @(posedge clk) begin
        if (!rst_n_g) commit_count_pmu_q <= '0;
        else          commit_count_pmu_q <= commit_count_pmu;
    end

    always_ff @(posedge clk) begin
        if (!rst_n_g) begin
            cycle_count  <= '0;
            commit_total <= '0;
        end else begin
            cycle_count  <= cycle_count + 1;
            commit_total <= commit_total + {61'h0, commit_count_pmu_q};
        end
    end

    assign perf_ipc    = (cycle_count > 999) ? (commit_total << 10) : 64'h0;
    assign core_active = |rob_commit_valid;

    // NOC RX/TX muxes and arbiters
    always_comb begin
        ext_rx_valid_int     = '0; ext_rx_flit_type_int = '0;
        ext_rx_dest_x_int    = '0; ext_rx_dest_y_int    = '0;
        ext_rx_payload_int   = '0;
        if (noc_rx_valid) begin
            case (noc_rx_port_id)
                3'd1: begin ext_rx_valid_int[1]=1'b1; ext_rx_flit_type_int[1]=noc_rx_flit_type; ext_rx_dest_x_int[1]=noc_rx_dest_x; ext_rx_dest_y_int[1]=noc_rx_dest_y; ext_rx_payload_int[1]=noc_rx_data; end
                3'd2: begin ext_rx_valid_int[2]=1'b1; ext_rx_flit_type_int[2]=noc_rx_flit_type; ext_rx_dest_x_int[2]=noc_rx_dest_x; ext_rx_dest_y_int[2]=noc_rx_dest_y; ext_rx_payload_int[2]=noc_rx_data; end
                3'd3: begin ext_rx_valid_int[3]=1'b1; ext_rx_flit_type_int[3]=noc_rx_flit_type; ext_rx_dest_x_int[3]=noc_rx_dest_x; ext_rx_dest_y_int[3]=noc_rx_dest_y; ext_rx_payload_int[3]=noc_rx_data; end
                3'd4: begin ext_rx_valid_int[4]=1'b1; ext_rx_flit_type_int[4]=noc_rx_flit_type; ext_rx_dest_x_int[4]=noc_rx_dest_x; ext_rx_dest_y_int[4]=noc_rx_dest_y; ext_rx_payload_int[4]=noc_rx_data; end
                default: ;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n_g) begin
            tx_arb_ptr <= 3'd1;
            noc_tx_valid <= 1'b0;
            ext_tx_ready_int <= '0;
            noc_tx_data <= 64'h0;
            noc_tx_flit_type <= 2'b0;
            noc_tx_port_id <= 3'b0;
        end else begin
            noc_tx_valid <= 1'b0;
            ext_tx_ready_int <= '0;
            for (int p = 0; p < 4; p++) begin
                automatic int port = (tx_arb_ptr - 1 + p) % 4 + 1;
                if (ext_tx_valid_int[port] && noc_tx_ready) begin
                    noc_tx_data <= ext_tx_payload_int[port];
                    noc_tx_flit_type <= ext_tx_flit_type_int[port];
                    noc_tx_port_id <= port;
                    noc_tx_valid <= 1'b1;
                    ext_tx_ready_int[port] <= 1'b1;
                    tx_arb_ptr <= (port % 4) + 1;
                    break;
                end
            end
        end
    end

    assign branch_update_valid  = branch_resolved;
    assign branch_update_pc     = rs_issue_uops[1].pc;
    assign branch_actual_taken  = (rs_issue_uops[1].opcode[6:0] == 7'h6F || rs_issue_uops[1].opcode[6:0] == 7'h67) ? 1'b1 : (rs_issue_uops[1].pred_taken ^ branch_mispredicted);
    assign branch_actual_target = branch_correct_pc;

    logic [2:0] allocate_branch_tag;
    logic [2:0] flush_branch_tag_ren;

    lotus_l1i_cache u_l1i_cache (
        .clk(clk), .rst_n(rst_n_g), .cpu_req_valid(ifu_req_valid), .cpu_req_pc(ifu_req_pc),
        .cpu_req_ready(ifu_req_ready), .cpu_resp_valid(l1i_resp_valid), .cpu_resp_data(l1i_resp_data), .cpu_resp_hit(l1i_resp_hit),
        .mem_req_valid(l1i_mem_req_valid), .mem_req_addr(l1i_mem_req_addr), .mem_req_ready(l1i_mem_req_ready), .mem_resp_valid(l1i_mem_resp_valid), .mem_resp_data(l1i_mem_resp_data)
    );

    lotus_ifu_masterpiece u_ifu (
        .clk(clk), .rst_n(rst_n_g), .flush(rob_flush_reg), .flush_target_pc(rob_flush_target_pc),
        .tage_pred_taken(tage_taken), .tage_pred_target(tage_predicted_pc),
        .l1i_req_valid(ifu_req_valid), .l1i_req_pc(ifu_req_pc), .l1i_req_ready(ifu_req_ready), .l1i_resp_valid(l1i_resp_valid), .l1i_resp_data(l1i_resp_data),
        .dec_ready(ifu_dec_ready), .out_packet(ifu_dec_packet), .out_valid(ifu_dec_valid)
    );
    assign fetch_ready = ifu_req_ready;

    lotus_tage_predictor u_tage (
        .clk(clk), .rst_n(rst_n_g), .current_pc(ifu_req_pc), .pred_taken(tage_taken), .pred_target(tage_predicted_pc),
        .resolve_valid(branch_update_valid), .resolve_pc(branch_update_pc), .resolve_taken(branch_actual_taken), .resolve_target(branch_actual_target),
        .perf_predictions(tage_perf_predictions), .perf_mispredicts(tage_perf_mispredicts)
    );

    lotus_decoder_masterpiece u_decoder (
        .clk(clk), .rst_n(rst_n_g), .flush(rob_flush_reg), .fetch_in(ifu_dec_packet), .fetch_valid(ifu_dec_valid),
        .fetch_ready(ifu_dec_ready), .dispatch_uop(dec_uops), .dispatch_valid(dec_uop_valid), .dispatch_ready(dec_dispatch_ready)
    );

    lotus_renamer_masterpiece #(.PHYS_REGS(128), .ARCH_REGS(32), .MAX_BR(8)) u_renamer (
        .clk(clk), .rst_n(rst_n_g), .flush(rob_flush_reg), .flush_branch_valid(rob_flush_reg), .flush_branch_tag(flush_branch_tag_reg),
        .save_checkpoint(dec_uop_valid[0] && dec_uops[0].is_branch), .save_branch_tag(allocate_branch_tag),
        .in_uop(dec_uops), .in_valid(dec_uop_valid), .out_uop(ren_uops), .out_valid(ren_uop_valid),
        .rename_ready(renamer_ready), .free_list_count(free_list_count), .commit_valid(commit_valid_renamer), .commit_p_old_dest(commit_p_old_dest)
    );

    assign rs_issue_ready = 4'b1111;

    // =========================================================================
    // FIX TOP-DEADLOCK-01: Gating dispatch_valid strictly with ren_uop_valid 
    //                      (Removed combinational dec_dispatch_ready mask).
    // =========================================================================
    lotus_reservation_station_v4 #(.RS_DEPTH(RS_DEPTH)) u_rs (
        .clk(clk), .rst_n(rst_n_g), .flush(rob_flush_reg),
        .dispatch_valid(ren_uop_valid), .dispatch_uop(ren_uops), .dispatch_branch_tag(rs_dispatch_branch_tag),
        .dispatch_rob_idx(rob_alloc_idx), .rs_ready(rs_ready_out),
        .cdb_valid(rs_cdb_valid), .cdb_p_dest(rs_cdb_p_dest), .cdb_data(rs_cdb_data),
        .prf_rd_addr(prf_rd_addr), .prf_rd_data(prf_rd_data), .prf_ready_bits(prf_ready_bits),
        .issue_valid(rs_issue_valid), .issue_rob_idx(rs_issue_rob_idx), .issue_uop(rs_issue_uops), .issue_src1(rs_issue_src1), .issue_src2(rs_issue_src2), .issue_ready(rs_issue_ready),
        .free_slots(), .rs_full()
    );

    always_comb for (int k = 0; k < 4; k++) rs_dispatch_branch_tag[k] = dec_uops[k].is_branch ? allocate_branch_tag : 3'b0;

    logic [1:0] br_tag_cnt;
    always_ff @(posedge clk)
        if (!rst_n_g) br_tag_cnt <= 0;
        else if (dec_uop_valid[0] && dec_uops[0].is_branch) br_tag_cnt <= br_tag_cnt + 1;
    assign allocate_branch_tag = {1'b0, br_tag_cnt};

    assign rob_dispatch_valid = ren_uop_valid;
    always_comb begin for (int i = 0; i < 4; i++) rob_dispatch_uop[i] = ren_uops[i]; end

    // =========================================================================
    // === TIMING FIX ROB-TIMING-01: ROB uses REGISTERED CDB inputs ===
    // =========================================================================
    lotus_rob_masterpiece #(.ROB_ENTRIES(ROB_ENTRIES)) u_rob (
        .clk(clk), .rst_n(rst_n_g), .flush(rob_flush_reg),
        .dispatch_valid(rob_dispatch_valid), .dispatch_uop(rob_dispatch_uop),
        .rob_ready(rob_ready), .alloc_rob_idx(rob_alloc_idx),
        .cdb_valid(rob_cdb_valid_q),
        .cdb_rob_idx(rob_cdb_rob_idx_q),
        .cdb_data(rob_cdb_data_q),
        .cdb_exception(rob_cdb_exception_q),
        .cdb_exc_cause(rob_cdb_exc_cause_q),
        .commit_valid(rob_commit_valid), .commit_p_dest(rob_commit_p_dest),
        .commit_p_old_dest(rob_commit_p_old_dest),
        .commit_data(rob_commit_data), .commit_is_store(rob_commit_is_store),
        .commit_lsq_idx(rob_commit_lsq_idx), .commit_rob_idx(rob_commit_rob_idx),
        .commit_ack(commit_ack), .flush_req(rob_flush_req), .flush_target_pc(rob_flush_target),
        .mtvec(mtvec_from_csr), .exception_valid(rob_exception_valid),
        .exception_cause(rob_exception_cause), .exception_pc(rob_exception_pc),
        .rob_occupancy(rob_occupancy), .rob_full(rob_full), .rob_empty(rob_empty)
    );

    assign rob_exception_flush = rob_flush_req;
    assign exception_internal  = rob_exception_valid;
    assign exception_out       = exception_internal;

    always_ff @(posedge clk) begin
        if (!rst_n_g) begin commit_valid_renamer <= '0; for (int i = 0; i < 4; i++) commit_p_old_dest[i] <= '0; end
        else begin commit_valid_renamer <= rob_commit_valid; for (int i = 0; i < 4; i++) commit_p_old_dest[i] <= rob_commit_p_old_dest[i]; end
    end

    // === TIMING FIX #3: PRF instance - commit/stall ports wired ===
    lotus_prf #(.PHYS_REGS(PRF_ENTRIES), .READ_PORTS(8), .WRITE_PORTS(4)) u_prf (
        .clk(clk), .rst_n(rst_n_g),
        .rd_addr(prf_rd_addr_p), .rd_data(prf_rd_data_p),
        .wr_addr(prf_wr_addr_p), .wr_data(prf_wr_data_p),
        .wr_en(prf_wr_en), .wr_rob_idx(prf_wr_rob_p),
        .prf_commit_valid(prf_commit_valid),
        .prf_commit_addr(prf_commit_addr),
        .prf_stall(prf_stall)
    );

    logic [3:0][6:0]  alu_cdb_p_dest_in_p; logic [3:0][63:0] alu_cdb_data_in_p; logic [3:0] alu_cdb_valid_in_p;
    always_comb begin for (int i = 0; i < 4; i++) begin alu_cdb_p_dest_in_p[i] = rs_cdb_p_dest[i]; alu_cdb_data_in_p[i] = rs_cdb_data[i]; alu_cdb_valid_in_p[i] = rs_cdb_valid[i]; end end

    // =========================================================================
    // 🛠️ V11.0 FIX: ALU uses RS forwarded operands, NOT stale PRF reads
    // =========================================================================
    lotus_alu_masterpiece u_alu (
        .clk(clk), .rst_n(rst_n_g), .flush(rob_flush_reg), .uop_in(rs_issue_uops[0]), .valid_in(rs_issue_valid[0]),
        .prf_src1_data(rs_issue_src1[0]), .prf_src2_data(rs_issue_src2[0]),  // FIXED: Use RS forwarded operands
        .cdb_p_dest_in(alu_cdb_p_dest_in_p), .cdb_data_in(alu_cdb_data_in_p), .cdb_valid_in(alu_cdb_valid_in_p),
        .cdb_p_dest_out(alu_cdb_p_dest), .cdb_data_out(alu_cdb_data), .cdb_valid_out(alu_cdb_valid)
    );

    // =========================================================================
    // 🛠️ V11.0 FIX: Branch uses RS forwarded operands, NOT stale PRF reads
    // =========================================================================
    lotus_branch_exec u_branch_exec (
        .clk(clk), .rst_n(rst_n_g), .issue_valid(rs_issue_valid[1]), .issue_pc(rs_issue_uops[1].pc), .issue_opcode(rs_issue_uops[1].opcode), .issue_funct3(rs_issue_uops[1].funct3),
        .issue_src1(rs_issue_src1[1]), .issue_src2(rs_issue_src2[1]), .issue_imm(rs_issue_uops[1].imm_data), .issue_p_dest(rs_issue_uops[1].p_dest),  // FIXED
        .issue_pred_taken(rs_issue_uops[1].pred_taken), .issue_pred_target(rs_issue_uops[1].pred_target), .issue_branch_tag(rs_issue_uops[1].branch_tag),
        .cdb_valid(branch_cdb_valid), .cdb_p_dest(branch_cdb_p_dest), .cdb_data(branch_cdb_data),
        .branch_resolved(branch_resolved), .branch_correct_pc_valid(branch_correct_pc_valid), .branch_correct_pc(branch_correct_pc),
        .branch_mispredict(branch_mispredicted), .branch_tag_out(flush_branch_tag_ren), .perf_mispredict(branch_perf_mispredict)
    );

    // =========================================================================
    // 🛠️ V11.0 FIX: AGU uses RS forwarded operands, NOT stale PRF reads
    // This fixes "STORE DRAIN addr=0000000000000000" bug!
    // =========================================================================
    lotus_agu u_agu (
        .clk(clk), .rst_n(rst_n_g), .flush(rob_flush_reg), .uop_in(rs_issue_uops[2]), .valid_in(rs_issue_valid[2]),
        .prf_base_data(rs_issue_src1[2]), .prf_store_data(rs_issue_src2[2]),  // FIXED: Use RS forwarded operands
        .agu_valid_out(agu_valid), .agu_is_store_out(agu_is_store), .agu_addr_out(agu_addr), .agu_data_out(agu_data), .agu_wmask_out(agu_wmask),
        .misalign_exception(agu_misalign), .misalign_addr(agu_misalign_addr)
    );

    // =========================================================================
    // 🛠️ V11.1 FIX: LSQ Deadlock Fix - Only allocate STORES into the SQ.
    // Loads bypass SQ allocation to prevent SQ pollution and drain blocking.
    // =========================================================================
    lotus_lsq_masterpiece u_lsq (
        .clk(clk), .rst_n(rst_n_g), .flush(rob_flush_reg),
        .alloc_valid(rs_issue_valid[2] && rs_issue_uops[2].is_memory && (rs_issue_uops[2].opcode[6:0] == 7'b0100011)), 
        .alloc_is_store(rs_issue_valid[2] && rs_issue_uops[2].is_memory && (rs_issue_uops[2].opcode[6:0] == 7'b0100011)),
        .alloc_rob_idx(rs_issue_rob_idx[2]), .sq_ready(), .alloc_sq_idx(),
        .agu_valid(agu_valid), .agu_is_store(agu_is_store), .agu_rob_idx(agu_rob_idx_q), .agu_addr(agu_addr), .agu_data(agu_data), .agu_wmask(agu_wmask),
        .load_fwd_valid(load_fwd_valid), .load_fwd_data(load_fwd_data), .load_needs_cache(load_needs_cache),
        .commit_valid(lsq_commit_valid_q),
        .commit_is_store(lsq_commit_is_store_q),
        .commit_rob_idx(lsq_commit_rob_idx_q),
        .l1d_req_valid(lsq_l1d_req_valid), .l1d_req_rw(lsq_l1d_req_rw), .l1d_req_addr(lsq_l1d_req_addr), .l1d_req_data(lsq_l1d_req_data), .l1d_req_wmask(lsq_l1d_req_wmask), .l1d_req_ready(lsq_l1d_req_ready)
    );

    // =========================================================================
    // FLOW CONTROL GATES (V10.6: EXPLICIT UNIFIED BUSES TO FIX VIVADO TRUNCATION)
    // =========================================================================
    logic        lsu_gate_upstream_valid, lsu_gate_upstream_ready;
    logic        lsu_gate_downstream_valid, lsu_gate_downstream_ready;
    logic        l1d_req_valid_int, l1d_req_rw_int;
    logic [63:0] l1d_req_addr_int, l1d_req_data_int;
    logic [7:0]  l1d_req_wmask_int;

    assign lsu_gate_upstream_valid = lsq_l1d_req_valid;

    // V10.6: Explicit Buses for LSU
    logic [136:0] lsu_upstream_bus;
    logic [136:0] lsu_downstream_bus;
    
    assign lsu_upstream_bus = {lsq_l1d_req_addr, lsq_l1d_req_data, lsq_l1d_req_wmask, lsq_l1d_req_rw};
    assign {l1d_req_addr_int, l1d_req_data_int, l1d_req_wmask_int, l1d_req_rw_int} = lsu_downstream_bus;

    congestion_aware_flow_gate #(.DATA_WIDTH(137), .FIFO_DEPTH(LSU_FIFO_DEPTH), .LOG2_FIFO_DEPTH($clog2(LSU_FIFO_DEPTH))) u_lsu_flow_gate (
        .clk(clk), .rst_n(rst_n_g),
        .upstream_valid(lsu_gate_upstream_valid),
        .upstream_ready(lsu_gate_upstream_ready),
        .upstream_data(lsu_upstream_bus),
        .downstream_valid(lsu_gate_downstream_valid),
        .downstream_ready(lsu_gate_downstream_ready),
        .downstream_data(lsu_downstream_bus),
        .gate_enable(1'b1), .throttle_limit(8'hFF), .max_outstanding(8'd16),
        .gate_stalled(lsu_gate_stalled), .fifo_count(lsu_fifo_count), .credit_count(lsu_credit_count), .duty_cycle_actual()
    );

    assign lsq_l1d_req_ready = lsu_gate_upstream_ready;
    assign l1d_req_valid_int = lsu_gate_downstream_valid;

    // DRAM gate
    logic        dram_gate_upstream_valid, dram_gate_upstream_ready, dram_gate_downstream_valid;
    logic        dram_req_valid_from_l2, dram_req_rw_from_l2;
    logic [63:0] dram_req_addr_from_l2; logic [1023:0] dram_req_data_from_l2;
    logic        dram_req_rw_gated; logic [63:0] dram_req_addr_gated; logic [1023:0] dram_req_data_gated;

    assign dram_gate_upstream_valid = dram_req_valid_from_l2;

    // V10.6: Explicit Buses for DRAM
    logic [1088:0] dram_upstream_bus;
    logic [1088:0] dram_downstream_bus;

    assign dram_upstream_bus = {dram_req_addr_from_l2, dram_req_data_from_l2, dram_req_rw_from_l2};
    assign {dram_req_addr_gated, dram_req_data_gated, dram_req_rw_gated} = dram_downstream_bus;

    congestion_aware_flow_gate #(.DATA_WIDTH(1089), .FIFO_DEPTH(DRAM_FIFO_DEPTH), .LOG2_FIFO_DEPTH($clog2(DRAM_FIFO_DEPTH))) u_dram_flow_gate (
        .clk(clk), .rst_n(rst_n_g),
        .upstream_valid(dram_gate_upstream_valid),
        .upstream_ready(dram_gate_upstream_ready),
        .upstream_data(dram_upstream_bus),
        .downstream_valid(dram_gate_downstream_valid),
        .downstream_ready(1'b1),
        .downstream_data(dram_downstream_bus),
        .gate_enable(1'b1), .throttle_limit(8'hFF), .max_outstanding(8'd8),
        .gate_stalled(dram_gate_stalled), .fifo_count(dram_fifo_count), .credit_count(dram_credit_count), .duty_cycle_actual()
    );
    assign dram_req_valid = dram_gate_downstream_valid; 
    assign dram_req_rw    = dram_req_rw_gated; 
    assign dram_req_addr  = dram_req_addr_gated; 
    assign dram_req_data  = dram_req_data_gated;

    // NOC gate
    logic noc_gate_upstream_valid, noc_gate_upstream_ready, noc_gate_downstream_valid; 
    
    // V10.6: Explicit Buses for NOC
    logic [68:0] noc_upstream_bus;
    logic [68:0] noc_downstream_bus;
    logic [68:0] noc_gate_downstream_data;

    assign noc_gate_upstream_valid = noc_tx_valid;
    assign noc_upstream_bus = {noc_tx_data, noc_tx_flit_type, noc_tx_port_id};
    assign noc_gate_downstream_data = noc_downstream_bus;

    congestion_aware_flow_gate #(.DATA_WIDTH(69), .FIFO_DEPTH(NOC_FIFO_DEPTH), .LOG2_FIFO_DEPTH($clog2(NOC_FIFO_DEPTH))) u_noc_flow_gate (
        .clk(clk), .rst_n(rst_n_g),
        .upstream_valid(noc_gate_upstream_valid),
        .upstream_ready(noc_gate_upstream_ready),
        .upstream_data(noc_upstream_bus),
        .downstream_valid(noc_gate_downstream_valid),
        .downstream_ready(noc_tx_ready),
        .downstream_data(noc_downstream_bus),
        .gate_enable(1'b1), .throttle_limit(8'hFF), .max_outstanding(8'd8),
        .gate_stalled(noc_gate_stalled), .fifo_count(noc_fifo_count), .credit_count(noc_credit_count), .duty_cycle_actual()
    );

    // Tensor gate (Stubbed)
    logic tensor_gate_upstream_valid, tensor_gate_upstream_ready, tensor_gate_downstream_valid; 
    logic [127:0] tensor_gate_downstream_data;
    
    assign tensor_gate_upstream_valid = 1'b0;
    
    congestion_aware_flow_gate #(.DATA_WIDTH(128), .FIFO_DEPTH(TENSOR_FIFO_DEPTH), .LOG2_FIFO_DEPTH($clog2(TENSOR_FIFO_DEPTH))) u_tensor_flow_gate (
        .clk(clk), .rst_n(rst_n_g),
        .upstream_valid(tensor_gate_upstream_valid),
        .upstream_ready(tensor_gate_upstream_ready),
        .upstream_data(128'h0),
        .downstream_valid(tensor_gate_downstream_valid),
        .downstream_ready(1'b1),
        .downstream_data(tensor_gate_downstream_data),
        .gate_enable(tensor_en_csr), .throttle_limit(8'hFF), .max_outstanding(8'd4),
        .gate_stalled(tensor_gate_stalled), .fifo_count(tensor_fifo_count), .credit_count(tensor_credit_count), .duty_cycle_actual()
    );

    // =========================================================================
    // TENSOR ENGINE & MEMORY ARBITER INTEGRATION
    // =========================================================================
    lotus_tensor_mem_arbiter u_tensor_arbiter (
        .clk              (clk), .rst_n            (rst_n_g),
        .cpu_req_valid    (l1d_req_valid_int), .cpu_req_rw        (l1d_req_rw_int),
        .cpu_req_addr     (l1d_req_addr_int), .cpu_req_data       (l1d_req_data_int),
        .cpu_req_wmask    (l1d_req_wmask_int),.cpu_req_ready     (lsu_gate_downstream_ready),
        .tensor_req_valid (ten_mem_req_valid), .tensor_req_ready (arb_to_ten_mem_ready), .tensor_req_addr(ten_mem_req_addr),
        .l1d_req_valid    (arb_to_l1d_req_valid), .l1d_req_rw        (arb_to_l1d_req_rw),
        .l1d_req_addr     (arb_to_l1d_req_addr), .l1d_req_data       (arb_to_l1d_req_data),
        .l1d_req_wmask    (arb_to_l1d_req_wmask),.l1d_req_ready    (l1d_to_arb_req_ready),
        .l1d_resp_valid   (l1d_cpu_resp_valid), .l1d_resp_data    (l1d_cpu_resp_data),
        .cpu_resp_valid   (), .cpu_resp_data    (),
        .tensor_resp_valid(arb_to_ten_resp_valid), .tensor_resp_data (arb_to_ten_resp_data)
    );

    lotus_tensor_engine #(.DRAIN_LATENCY(24)) u_tensor_engine (
        .clk              (clk), .rst_n            (rst_n_g), .flush              (rob_flush_reg),
        .issue_valid      (rs_issue_valid[3] && rs_issue_uops[3].is_tensor_op && engine_ready),
        .issue_p_dest     (rs_issue_uops[3].p_dest), .issue_base_addr  (prf_rd_data[6]),
        .issue_funct3     (rs_issue_uops[3].funct3),
        .issue_precision  (precision_mode),
        .mem_req_valid    (ten_mem_req_valid), .mem_req_addr     (ten_mem_req_addr),
        .mem_req_ready    (arb_to_ten_mem_ready), .mem_resp_valid   (arb_to_ten_resp_valid), .mem_resp_data(arb_to_ten_resp_data),
        .weight_bf16_out  (tensor_weight_bf16), .input_bf16_out   (tensor_input_bf16),
        .weight_int8_out  (tensor_weight_int8), .input_int8_out   (tensor_input_int8),
        .array_enable     (tensor_array_enable), .tensor_array_busy(tensor_array_busy),
        .feed_first       (tensor_feed_first),
        .bf16_results     (tensor_bf16_results), .int8_results      (tensor_int8_out),
        .tensor_cdb_valid (ten_cdb_valid), .tensor_cdb_p_dest(ten_cdb_p_dest), .tensor_cdb_data(ten_cdb_data),
        .tensor_cdb_ready (1'b1), .engine_ready     (engine_ready)
    );

    // =========================================================================
    // L1D / L2 CACHE (Fed via Arbiter)
    // =========================================================================
    logic [511:0] l1d_to_l2_data;

    lotus_l1d_cache u_l1d_cache (
        .clk(clk), .rst_n(rst_n_g),
        .cpu_req_valid(arb_to_l1d_req_valid), .cpu_req_rw(arb_to_l1d_req_rw), .cpu_req_addr(arb_to_l1d_req_addr),
        .cpu_req_data(arb_to_l1d_req_data), .cpu_req_wmask(arb_to_l1d_req_wmask), .cpu_req_ready(l1d_to_arb_req_ready),
        .cpu_resp_valid(l1d_cpu_resp_valid), .cpu_resp_data(l1d_cpu_resp_data), .cpu_resp_hit(l1d_cpu_resp_hit),
        .mem_req_valid(l1d_mem_req_valid), .mem_req_rw(l1d_mem_req_rw), .mem_req_addr(l1d_mem_req_addr), .mem_req_data(l1d_to_l2_data),
        .mem_req_ready(l1d_mem_req_ready), .mem_resp_valid(l1d_mem_resp_valid), .mem_resp_data(l1d_mem_resp_data)
    );

    lotus_l2_cache u_l2_cache (
        .clk(clk), .rst_n(rst_n_g),
        .l1d_req_valid(l1d_mem_req_valid), .l1d_req_rw(l1d_mem_req_rw), .l1d_req_addr(l1d_mem_req_addr), .l1d_req_data(l1d_to_l2_data), .l1d_req_ready(l1d_mem_req_ready),
        .l1d_resp_valid(l2_l1d_resp_valid), .l1d_resp_data(l2_l1d_resp_data),
        .l1i_req_valid(l1i_mem_req_valid), .l1i_req_addr(l1i_mem_req_addr), .l1i_req_ready(l1i_mem_req_ready), .l1i_resp_valid(l1i_mem_resp_valid), .l1i_resp_data(l1i_mem_resp_data),
        .dram_req_valid(dram_req_valid_from_l2), .dram_req_rw(dram_req_rw_from_l2), .dram_req_addr(dram_req_addr_from_l2), .dram_req_data(dram_req_data_from_l2), .dram_req_ready(dram_gate_upstream_ready),
        .dram_resp_valid(dram_resp_valid), .dram_resp_data(dram_resp_data)
    );

    assign l1d_mem_resp_valid = l2_l1d_resp_valid;
    assign l1d_mem_resp_data  = l2_l1d_resp_data;

    // PMU
    logic [63:0] pmu_csr_rd_data;
    lotus_pmu u_pmu (
        .clk(clk), .rst_n(rst_n_g), .ev_cycle(1'b1), .ev_instr_commit(|rob_commit_valid), .ev_commit_count(commit_count_pmu),
        .ev_l1d_hit(l1d_cpu_resp_hit), .ev_l1d_miss(l1d_mem_req_valid), .ev_l2_hit(l2_l1d_resp_valid & ~dram_req_valid), .ev_l2_miss(dram_req_valid),
        .ev_branch_pred(branch_resolved), .ev_branch_mispredict(branch_mispredicted), .ev_fetch_stall(~ifu_dec_valid & ifu_dec_ready),
        .ev_rob_full_stall(~rob_ready), .ev_rs_full_stall(~rs_ready_out),
        .ev_tensor_active(!engine_ready), .ev_sparsity_skip(sparsity_to_tensor_valid && (sparsity_nz_count < 8)),
        .csr_addr(12'h0), .csr_rd_en(1'b0), .csr_rd_data(pmu_csr_rd_data), .csr_wr_en(1'b0), .csr_wr_data(64'h0)
    );

    // CSR
    assign csr_issue_valid = (rs_issue_valid[0] && rs_issue_uops[0].is_csr) || (rs_issue_valid[1] && rs_issue_uops[1].is_csr) || (rs_issue_valid[2] && rs_issue_uops[2].is_csr) || (rs_issue_valid[3] && rs_issue_uops[3].is_csr);
    always_comb begin
        csr_issue_uop = '0; csr_src1_data = '0;
        if      (rs_issue_valid[0] && rs_issue_uops[0].is_csr) {csr_issue_uop, csr_src1_data} = {rs_issue_uops[0], prf_rd_data[0]};
        else if (rs_issue_valid[1] && rs_issue_uops[1].is_csr) {csr_issue_uop, csr_src1_data} = {rs_issue_uops[1], prf_rd_data[2]};
        else if (rs_issue_valid[2] && rs_issue_uops[2].is_csr) {csr_issue_uop, csr_src1_data} = {rs_issue_uops[2], prf_rd_data[4]};
        else if (rs_issue_valid[3] && rs_issue_uops[3].is_csr) {csr_issue_uop, csr_src1_data} = {rs_issue_uops[3], prf_rd_data[6]};
    end

    // =========================================================================
    // CSR (Hardcoded Tensor controls)
    // =========================================================================
    assign precision_mode = 2'b00;
    assign sparsity_en_csr = 1'b0;
    assign tensor_en_csr = 1'b1;

    lotus_csr u_csr (
        .clk(clk), .rst_n(rst_n_g),
        .csr_addr(csr_issue_uop.imm_data[11:0]),
        .csr_op(csr_issue_uop.funct3[1:0]),
        .csr_wdata(csr_src1_data),
        .csr_valid(csr_issue_valid),
        .fence_instr(1'b0),
        .fence_i_instr(1'b0),
        .csr_rdata(csr_rdata_out),
        .csr_illegal(csr_illegal_out),
        .fence_complete(),
        .fence_i_complete(),
        .exception_valid(exception_internal),
        .exception_pc(exception_pc_w),
        .exception_cause(exception_cause_w),
        .exception_tval(64'h0),
        .mtvec_out(mtvec_from_csr),
        .mepc_out(mepc_from_csr),
        .precision_mode(),
        .sparsity_en(),
        .tensor_en()
    );

    // =========================================================================
    // SCOPING / IMPLICIT WIRE FIX (Moved to bottom)
    // =========================================================================
    always_comb begin
        // V10.8 FIX: AGU already pipelines internally, use direct signals
        agu_completes = (agu_valid & agu_is_store) | (agu_valid & agu_misalign);

        rob_cdb_valid[0]=alu_cdb_valid;
        rob_cdb_rob_idx[0]=rs_issue_rob_idx_q[0]; rob_cdb_data[0]=alu_cdb_data;
        rob_cdb_exception[0]=1'b0;                rob_cdb_exc_cause[0]=64'h0;

        rob_cdb_valid[1]=branch_cdb_valid;
        rob_cdb_rob_idx[1]=rs_issue_rob_idx_q[1]; rob_cdb_data[1]=branch_cdb_data;
        rob_cdb_exception[1]=1'b0;                rob_cdb_exc_cause[1]=64'h0;

        // Port 2 is strictly for Loads
        rob_cdb_valid[2]     = load_cdb_valid;
        rob_cdb_rob_idx[2]   = load_cdb_rob_idx_out;
        rob_cdb_data[2]      = load_cdb_data;
        rob_cdb_exception[2] = 1'b0;
        rob_cdb_exc_cause[2] = 64'h0;

        // Port 3 handles CSR, Tensor, and AGU (Stores/Misaligns)
        rob_cdb_valid[3]     = csr_cdb_valid | ten_cdb_valid | agu_completes;
        rob_cdb_rob_idx[3]   = agu_completes ? agu_rob_idx_q : (csr_cdb_valid ? csr_issue_rob_idx : rs_issue_rob_idx_q[3]);
        rob_cdb_data[3]      = csr_cdb_valid ? csr_cdb_data : ten_cdb_data;
        
        // V10.8 FIX: Use direct agu_misalign signal
        rob_cdb_exception[3] = agu_completes ? agu_misalign : (csr_illegal_out && csr_issue_valid);
        rob_cdb_exc_cause[3] = agu_completes ? 64'h4 : ((csr_illegal_out && csr_issue_valid) ? illegal_csr_cause : 64'h0);
    end

endmodule : lotus_omni_core_top_v2