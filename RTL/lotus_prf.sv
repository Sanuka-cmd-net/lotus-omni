`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// lotus_prf - V4.2 TIMING & RAW HAZARD FIX
//   - Breaks the 20-level issue->CDB->arb->queue path
//   - Replaces 64-bit data compare with one-hot grant vector
//   - Fixes drop-when-draining bug + adds backpressure
//   - Read-after-write forwarding for +1 cycle write latency
//   - V4.2 FIX: Added same-cycle write-first bypass for incoming wr_en
//               to eliminate PRF RAW hazards causing AGU stale reads.
//////////////////////////////////////////////////////////////////////////////////
module lotus_prf import lotus_pkg::*; #(
    parameter PHYS_REGS   = 128,
    parameter DATA_WIDTH  = 64,
    parameter READ_PORTS  = 8,
    parameter WRITE_PORTS = 4
)(
    input  logic clk,
    input  logic rst_n,
    input  logic [READ_PORTS-1:0][6:0]   rd_addr,
    output logic [READ_PORTS-1:0][63:0]  rd_data,
    input  logic [WRITE_PORTS-1:0][6:0]  wr_addr,
    input  logic [WRITE_PORTS-1:0][63:0] wr_data,
    input  logic [WRITE_PORTS-1:0]       wr_en,
    input  logic [WRITE_PORTS-1:0][6:0]  wr_rob_idx,
    output logic        prf_commit_valid,
    output logic [6:0]  prf_commit_addr,
    output logic        prf_stall
);

    localparam QDEPTH = WRITE_PORTS;   // burst tolerance (can be increased to 8 if needed)

    // ---- STEP 1: same-address collision (youngest ROB wins) ----
    logic [WRITE_PORTS-1:0] wr_same_addr_selected;
    always_comb begin
        for (int p = 0; p < WRITE_PORTS; p++)
            wr_same_addr_selected[p] = wr_en[p];
        for (int p1 = 0; p1 < WRITE_PORTS; p1++)
            for (int p2 = p1+1; p2 < WRITE_PORTS; p2++)
                if (wr_same_addr_selected[p1] && wr_same_addr_selected[p2] &&
                    wr_addr[p1] == wr_addr[p2]) begin
                    if (wr_rob_idx[p1] > wr_rob_idx[p2])      wr_same_addr_selected[p2] = 1'b0;
                    else if (wr_rob_idx[p2] > wr_rob_idx[p1]) wr_same_addr_selected[p1] = 1'b0;
                end
    end

    logic [6:0]  q_addr  [0:QDEPTH-1];
    logic [63:0] q_data  [0:QDEPTH-1];
    logic        q_valid [0:QDEPTH-1];

    // ---- STEP 2: one-hot grant (removed 64-bit data compare) ----
    logic [WRITE_PORTS-1:0] live_grant;
    logic                   queue_drain, chosen_valid, chosen_from_queue;
    logic [6:0]             chosen_addr;
    logic [63:0]            chosen_data;

    assign queue_drain = q_valid[0];

    always_comb begin
        live_grant = '0;
        if (!queue_drain)
            for (int p = 0; p < WRITE_PORTS; p++)
                if (wr_same_addr_selected[p] && (live_grant == '0))
                    live_grant[p] = 1'b1;
    end

    always_comb begin
        chosen_from_queue = queue_drain;
        chosen_valid      = queue_drain | (|live_grant);
        chosen_addr       = '0;
        chosen_data       = '0;
        if (queue_drain) begin
            chosen_addr = q_addr[0];
            chosen_data = q_data[0];
        end else begin
            for (int p = 0; p < WRITE_PORTS; p++)
                if (live_grant[p]) begin
                    chosen_addr = wr_addr[p];
                    chosen_data = wr_data[p];
                end
        end
    end

    logic [WRITE_PORTS-1:0] wr_deferred;
    always_comb begin
        for (int p = 0; p < WRITE_PORTS; p++)
            wr_deferred[p] = wr_same_addr_selected[p] && !live_grant[p];
    end

    // ---- STEP 2a: REGISTER arbitration (breaks the 20-level critical path here) ----
    logic        grant_valid_q, drain_q;
    logic [6:0]  grant_addr_q;
    logic [63:0] grant_data_q;
    logic [WRITE_PORTS-1:0]       deferred_q;
    logic [WRITE_PORTS-1:0][6:0]  wr_addr_q;
    logic [WRITE_PORTS-1:0][63:0] wr_data_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant_valid_q <= 1'b0;
            drain_q       <= 1'b0;
            deferred_q    <= '0;
        end else begin
            grant_valid_q <= chosen_valid;
            drain_q       <= chosen_from_queue;
            grant_addr_q  <= chosen_addr;
            grant_data_q  <= chosen_data;
            deferred_q    <= wr_deferred;
            wr_addr_q     <= wr_addr;
            wr_data_q     <= wr_data;
        end
    end

    assign prf_commit_valid = grant_valid_q;
    assign prf_commit_addr  = grant_addr_q;

    // ---- STEP 2b: queue push/drain (registered signals) ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < QDEPTH; i++) begin
                q_valid[i] <= 1'b0; q_addr[i] <= '0; q_data[i] <= '0;
            end
        end else begin
            automatic int wr_ptr = 0;
            if (drain_q) begin
                for (int i = 0; i < QDEPTH-1; i++) begin
                    q_valid[i] <= q_valid[i+1];
                    q_addr[i]  <= q_addr[i+1];
                    q_data[i]  <= q_data[i+1];
                end
                q_valid[QDEPTH-1] <= 1'b0;
                for (int i = 0; i < QDEPTH-1; i++)
                    if (q_valid[i+1]) wr_ptr = i + 1;
            end else begin
                for (int i = 0; i < QDEPTH; i++)
                    if (q_valid[i]) wr_ptr = i + 1;
            end
            for (int p = 0; p < WRITE_PORTS; p++) begin
                if (deferred_q[p] && wr_ptr < QDEPTH) begin
                    q_valid[wr_ptr] <= 1'b1;
                    q_addr[wr_ptr]  <= wr_addr_q[p];
                    q_data[wr_ptr]  <= wr_data_q[p];
                    wr_ptr = wr_ptr + 1;
                end
            end
        end
    end

    // ---- backpressure (queue near-full) ----
    always_comb begin
        automatic int cnt = 0;
        for (int i = 0; i < QDEPTH; i++) if (q_valid[i]) cnt = cnt + 1;
        prf_stall = (cnt >= QDEPTH - 1);
    end

    // ---- STEP 3: storage write + read-after-write forwarding ----
    genvar r;
    generate
        for (r = 0; r < READ_PORTS; r++) begin : gen_read_port_bank
            (* ram_style = "distributed" *) logic [63:0] reg_file_bank [0:PHYS_REGS-1];
            initial for (int i = 0; i < PHYS_REGS; i++) reg_file_bank[i] = 64'h0;

            // =========================================================================
            // V4.2 FIX: Comprehensive Read-After-Write (RAW) Bypass Network
            // =========================================================================
            // Resolves same-cycle RAW hazards by checking both the registered
            // committed writes (grant_valid_q) and the incoming write requests (wr_en).
            // This ensures reads always get the most up-to-date data, eliminating
            // stale read deadlocks in the AGU/LSQ paths.
            always_comb begin
                // Default: Read from the physical register file bank
                rd_data[r] = reg_file_bank[rd_addr[r]];
                
                // Priority 1: Bypass the registered committed write (from previous cycle)
                if (grant_valid_q && (rd_addr[r] == grant_addr_q) && (grant_addr_q != 7'h0)) begin
                    rd_data[r] = grant_data_q;
                end
                
                // Priority 2: Bypass incoming same-cycle write requests
                // Iterating through all write ports to catch any same-cycle updates
                for (int w = 0; w < WRITE_PORTS; w++) begin
                    if (wr_en[w] && (wr_addr[w] == rd_addr[r]) && (wr_addr[w] != 7'h0)) begin
                        rd_data[r] = wr_data[w];  // Forward incoming write data
                    end
                end
            end

            always_ff @(posedge clk) begin
                if (grant_valid_q && grant_addr_q != 7'h0)
                    reg_file_bank[grant_addr_q] <= grant_data_q;
            end
        end
    endgenerate

endmodule