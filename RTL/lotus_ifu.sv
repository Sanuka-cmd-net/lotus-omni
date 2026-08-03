// =========================================
// File Name: lotus_ifu.sv
// =========================================

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:       Lotus Omni (Fabless AI Semiconductor)
// Engineer:      Sanuka Nethmira Amarasekara
// Module Name:   lotus_ifu_masterpiece
// Description:   Instruction Fetch Unit - V1.1 (IFU Deadlock Fix Applied)
//
// FIX IFU-001: Separated backend stall from cache request stall.
//   Previously, if dec_ready was low, l1i_req_valid would also go low,
//   completely stalling the fetch pipeline and causing a system deadlock.
//   Now, IFU can still request cache lines even if the decoder is full,
//   it will simply hold the output packet steady until the decoder frees up.
//////////////////////////////////////////////////////////////////////////////////
module lotus_ifu_masterpiece import lotus_pkg::*; (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,
    input  logic [63:0] flush_target_pc,
    // Branch Prediction
    input  logic        tage_pred_taken,
    input  logic [63:0] tage_pred_target,
    // L1I Cache Interface
    output logic                  l1i_req_valid,
    output logic [63:0]           l1i_req_pc,
    input  logic                  l1i_req_ready,
    input  logic                  l1i_resp_valid,
    input  logic [511:0]          l1i_resp_data,
    // Decoder Interface
    input  logic                  dec_ready,
    output fetch_packet_t         out_packet,
    output logic                  out_valid,
    // Perf
    output logic [63:0]           perf_fetch_stalls,
    output logic [63:0]           perf_zombie_kills
);

    logic [63:0] current_pc;
    logic [63:0] next_pc;
    logic        stall;
    logic        bubble;

    // FIX IFU-001: Separate cache request stall from backend stall
    // If backend is stalled (dec_ready=0), we must still be able to request the cache
    // We just can't accept new data into out_packet until backend frees up.
    logic backend_stall;
    assign backend_stall = out_valid && !dec_ready;
    assign bubble        = flush; 

    // PC Update Logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_pc <= 64'h8000_0000;
        end else if (flush) begin
            current_pc <= flush_target_pc;
        end else if (!stall && !bubble && !backend_stall) begin // Added backend_stall check
            if (tage_pred_taken)
                current_pc <= tage_pred_target;
            else
                current_pc <= current_pc + 64'd64; // 16 instructions × 4 bytes
        end
    end

    // Cache Request - No longer gated by dec_ready!
    assign l1i_req_pc    = current_pc;
    assign l1i_req_valid = !stall && !bubble; 
    assign stall         = !l1i_req_ready;

    // Fetch Packet Assembly
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_packet <= '0;
        end else if (flush) begin
            out_valid <= 1'b0;
        end else if (backend_stall) begin
            // Do nothing, hold out_packet steady until decoder is ready
        end else if (l1i_resp_valid && !stall) begin
            out_packet.inst_block <= l1i_resp_data;
            out_packet.pc         <= current_pc;
            out_packet.pred_taken <= tage_pred_taken;
            out_packet.pred_target<= tage_pred_target;
            out_packet.valid_mask <= 16'hFFFF; // all 16 instructions valid
            out_valid             <= 1'b1;
        end else if (dec_ready && out_valid) begin
            out_valid <= 1'b0;
        end
    end

    // Perf Counters
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_fetch_stalls <= '0;
            perf_zombie_kills <= '0;
        end else begin
            if (stall) perf_fetch_stalls <= perf_fetch_stalls + 1;
            if (flush) perf_zombie_kills <= perf_zombie_kills + 1;
        end
    end

endmodule