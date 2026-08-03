`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: lotus_prefetcher - V1.6 MULTI-DRIVEN NET FIX IN FIFO
//
// FIX V1.6 (THIS VERSION):
//   Bug #12 (MULTI-DRIVEN NET IN FIFO): V1.5 used 4 independent `if` blocks 
//     to write to unrolled registers (mem_0 to mem_3). Vivado sees this as 
//     multi-driven nets -> [Synth 8-6859] error.
//     Fix: Consolidated the 4 `if` blocks into a single `case (tail)` block. 
//     Each register is now driven by exactly one path per tail state. This 
//     perfectly synthesizes as a high-speed circular buffer.
//////////////////////////////////////////////////////////////////////////////////

module lotus_prefetcher import lotus_pkg::*; #(
    parameter RPT_ENTRIES  = 16,
    parameter PREFETCH_DEG = 4
)(
    input  logic clk,
    input  logic rst_n,

    input  logic        access_valid,
    input  logic [63:0] access_pc,
    input  logic [63:0] access_addr,

    output logic        pf_req_valid,
    output logic [63:0] pf_req_addr,
    input  logic        pf_req_ready
);

    // =========================================================================
    // Reference Prediction Table (RPT) - SPLIT INTO LUTRAM ARRAYS
    // =========================================================================
    (* ram_style = "distributed" *) logic [63:0]        rpt_pc        [0:RPT_ENTRIES-1];
    (* ram_style = "distributed" *) logic [63:0]        rpt_prev_addr [0:RPT_ENTRIES-1];
    (* ram_style = "distributed" *) logic signed [63:0] rpt_stride    [0:RPT_ENTRIES-1];
    (* ram_style = "distributed" *) logic [1:0]         rpt_conf      [0:RPT_ENTRIES-1];
    (* ram_style = "distributed" *) logic               rpt_valid     [0:RPT_ENTRIES-1];

    // Power-up initialization for FPGA (Replaces synchronous for-loop reset)
    initial begin
        for (int i = 0; i < RPT_ENTRIES; i++) begin
            rpt_pc[i]        = '0;
            rpt_prev_addr[i] = '0;
            rpt_stride[i]    = '0;
            rpt_conf[i]      = '0;
            rpt_valid[i]     = '0;
        end
    end

    // PC Hash for index dispersion
    logic [3:0] rpt_idx;
    assign rpt_idx = access_pc[5:2] ^ access_pc[11:8];

    // =========================================================================
    // Prefetch queue Pointers & Count
    // =========================================================================
    logic [1:0]  pf_head, pf_tail;
    logic [2:0]  pf_count;

    assign pf_req_valid = (pf_count > 0);

    // =========================================================================
    // COMBINATIONAL: Stride & Push Data
    // =========================================================================
    logic signed [63:0] pf_new_stride;
    logic [2:0]         push_count_comb;
    logic [63:0]        push_data_0, push_data_1, push_data_2, push_data_3;

    always_comb begin
        pf_new_stride   = $signed(access_addr) - $signed(rpt_prev_addr[rpt_idx]);
        push_count_comb = 3'h0;
        push_data_0 = '0; push_data_1 = '0;
        push_data_2 = '0; push_data_3 = '0;

        if (access_valid && rpt_valid[rpt_idx] && rpt_pc[rpt_idx] == access_pc) begin
            if (pf_new_stride == rpt_stride[rpt_idx] &&
                rpt_conf[rpt_idx] >= 2'b10 &&
                pf_new_stride >= 0) begin
                if (pf_count < 4) begin
                    push_data_0 = access_addr + ($unsigned(pf_new_stride) * 1);
                    push_count_comb = 1;
                    if (pf_count + 1 < 4) begin
                        push_data_1 = access_addr + ($unsigned(pf_new_stride) * 2);
                        push_count_comb = 2;
                        if (pf_count + 2 < 4) begin
                            push_data_2 = access_addr + ($unsigned(pf_new_stride) * 3);
                            push_count_comb = 3;
                            if (pf_count + 3 < 4) begin
                                push_data_3 = access_addr + ($unsigned(pf_new_stride) * 4);
                                push_count_comb = 4;
                            end
                        end
                    end
                end
            end
        end
    end

    // =========================================================================
    // PREFETCH QUEUE STORAGE
    // =========================================================================
    logic [63:0] pf_req_addr_ram;

    pf_fifo_4deep u_pf_fifo (
        .clk        (clk),
        .head       (pf_head),
        .tail       (pf_tail),
        .push_count (push_count_comb),
        .push_data_0(push_data_0),
        .push_data_1(push_data_1),
        .push_data_2(push_data_2),
        .push_data_3(push_data_3),
        .rd_data    (pf_req_addr_ram)
    );

    assign pf_req_addr = pf_req_addr_ram;

    // =========================================================================
    // MAIN SEQUENTIAL LOGIC
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pf_head  <= 2'h0;
            pf_tail  <= 2'h0;
            pf_count <= 3'h0;
        end else begin
            // Drain prefetch queue
            if (pf_req_valid && pf_req_ready) begin
                pf_head  <= pf_head + 1'b1;
                pf_count <= pf_count - 1'b1;
            end

            // Process demand access
            if (access_valid) begin
                if (rpt_valid[rpt_idx] && rpt_pc[rpt_idx] == access_pc) begin
                    if (pf_new_stride == rpt_stride[rpt_idx]) begin
                        if (rpt_conf[rpt_idx] < 2'b11)
                            rpt_conf[rpt_idx] <= rpt_conf[rpt_idx] + 1'b1;

                        pf_tail <= pf_tail + push_count_comb[1:0];
                        if (pf_req_valid && pf_req_ready) begin
                            pf_count <= ((pf_count - 1'b1) + push_count_comb > 3'd4) ? 3'd4 : (pf_count - 1'b1) + push_count_comb;
                        end else begin
                            pf_count <= ((pf_count + push_count_comb) > 3'd4) ? 3'd4 : (pf_count + push_count_comb);
                        end
                    end else begin
                        rpt_stride[rpt_idx] <= pf_new_stride;
                        rpt_conf[rpt_idx]   <= 2'b01;
                    end
                    rpt_prev_addr[rpt_idx] <= access_addr;
                end else begin
                    rpt_valid[rpt_idx]      <= 1'b1;
                    rpt_pc[rpt_idx]         <= access_pc;
                    rpt_prev_addr[rpt_idx]  <= access_addr;
                    rpt_stride[rpt_idx]     <= 64'h0;
                    rpt_conf[rpt_idx]       <= 2'b00;
                end
            end
        end
    end

endmodule

// =========================================================================
// FIXED Parallel-In Serial-Out Register FIFO Module
// =========================================================================
module pf_fifo_4deep (
    input  logic        clk,
    input  logic [1:0]  head,
    input  logic [1:0]  tail,
    input  logic [2:0]  push_count,
    input  logic [63:0] push_data_0,
    input  logic [63:0] push_data_1,
    input  logic [63:0] push_data_2,
    input  logic [63:0] push_data_3,
    output logic [63:0] rd_data
);

    // Unrolled to individual registers to prevent Synth 8-4767 multi-port warning
    logic [63:0] mem_0, mem_1, mem_2, mem_3;

    // FIX V1.6: Consolidated into a single `case (tail)` block to prevent 
    // Multi-Driven Net errors (Synth 8-6859). Each register is assigned exactly 
    // once per clock cycle based on the tail pointer.
    always_ff @(posedge clk) begin
        case (tail)
            2'd0: begin
                if (push_count > 3'd0) mem_0 <= push_data_0;
                if (push_count > 3'd1) mem_1 <= push_data_1;
                if (push_count > 3'd2) mem_2 <= push_data_2;
                if (push_count > 3'd3) mem_3 <= push_data_3;
            end
            2'd1: begin
                if (push_count > 3'd0) mem_1 <= push_data_0;
                if (push_count > 3'd1) mem_2 <= push_data_1;
                if (push_count > 3'd2) mem_3 <= push_data_2;
                if (push_count > 3'd3) mem_0 <= push_data_3;
            end
            2'd2: begin
                if (push_count > 3'd0) mem_2 <= push_data_0;
                if (push_count > 3'd1) mem_3 <= push_data_1;
                if (push_count > 3'd2) mem_0 <= push_data_2;
                if (push_count > 3'd3) mem_1 <= push_data_3;
            end
            2'd3: begin
                if (push_count > 3'd0) mem_3 <= push_data_0;
                if (push_count > 3'd1) mem_0 <= push_data_1;
                if (push_count > 3'd2) mem_1 <= push_data_2;
                if (push_count > 3'd3) mem_2 <= push_data_3;
            end
        endcase
    end

    always_comb begin
        case (head)
            2'd0: rd_data = mem_0;
            2'd1: rd_data = mem_1;
            2'd2: rd_data = mem_2;
            2'd3: rd_data = mem_3;
        endcase
    end

endmodule