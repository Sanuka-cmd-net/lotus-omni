`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:       Lotus Omni (Fabless AI Semiconductor)
// Engineer:      Sanuka Nethmira Amarasekara
// Module Name:   lotus_agu - V1.2 wmask_9 Latch Fix
//
// Changes V1.2:
//   FIX AGU-LATCH-001: wmask_9 default assignment added at top of always_comb.
//     Previously wmask_9 was only assigned inside case branches 3'b000, 3'b001,
//     3'b010. The 3'b011 (LD/SD 8-byte) branch set wmask_comb=8'hFF but left
//     wmask_9 undriven, causing Vivado to infer a latch on wmask_9.
//     Fix: wmask_9 = 9'h1FF added as default before the case statement.
//
// Changes V1.1 (preserved):
//   - Misalignment detection uses direct address bit checks (no wmask overflow)
//   - 9-bit wmask shift kept only for mask generation (no truncation warning)
//   - Alignment rules: 1B → never misaligned
//                       2B → computed_addr[0] must be 0
//                       4B → computed_addr[1:0] must be 2'b00
//                       8B → computed_addr[2:0] must be 3'b000
//////////////////////////////////////////////////////////////////////////////////

module lotus_agu import lotus_pkg::*; (
    input  logic clk,
    input  logic rst_n,
    input  logic flush,

    // --- INPUT FROM RS (Issue Port 2) ---
    input  rs_entry_t uop_in,
    input  logic      valid_in,

    // --- PRF READ DATA ---
    input  logic [63:0] prf_base_data,   // rs1 - base address
    input  logic [63:0] prf_store_data,  // rs2 - store data

    // --- OUTPUT TO LSQ ---
    output logic        agu_valid_out,
    output logic        agu_is_store_out,
    output logic [3:0]  agu_sq_idx_out,
    output logic [63:0] agu_addr_out,
    output logic [63:0] agu_data_out,
    output logic [7:0]  agu_wmask_out,

    // --- EXCEPTION ---
    output logic        misalign_exception,
    output logic [63:0] misalign_addr
);

    // -------------------------------------------------------------------------
    // Address computation - combinational
    // -------------------------------------------------------------------------
    logic [63:0] computed_addr;
    logic        is_store_comb;
    logic [7:0]  wmask_comb;
    logic [8:0]  wmask_9;          // 9-bit temp to avoid truncation warning
    logic        misalign_comb;

    // Local constants for opcode comparison
    localparam [6:0] OPCODE_STORE = 7'b0100011;  // RV64I STORE

    always_comb begin
        computed_addr = prf_base_data + uop_in.imm_data;
        is_store_comb = uop_in.is_memory && (uop_in.opcode[6:0] == OPCODE_STORE);

        // Defaults: full 64-bit write, aligned
        wmask_comb    = 8'hFF;
        wmask_9       = 9'h1FF;   // FIX AGU-LATCH-001: default prevents latch on wmask_9
        misalign_comb = 1'b0;

        case (uop_in.funct3)
            3'b000: begin // LB / SB (1 byte)
                wmask_9      = 9'h001 << computed_addr[2:0];
                wmask_comb   = wmask_9[7:0];
                // misalign_comb stays 0 - single byte is never misaligned
            end

            3'b001: begin // LH / SH (2 bytes)
                wmask_9      = 9'h003 << computed_addr[2:0];
                wmask_comb   = wmask_9[7:0];
                // Misaligned if any of the low 1 bit is set
                misalign_comb = computed_addr[0];
            end

            3'b010: begin // LW / SW (4 bytes)
                wmask_9      = 9'h00F << computed_addr[2:0];
                wmask_comb   = wmask_9[7:0];
                // Misaligned if any of the low 2 bits are set
                misalign_comb = |computed_addr[1:0];
            end

            3'b011: begin // LD / SD (8 bytes)
                wmask_comb    = 8'hFF;      // full quadword
                // wmask_9 left at default 9'h1FF (no shift needed for full-width)
                // Misaligned if any of the low 3 bits are set
                misalign_comb = |computed_addr[2:0];
            end

            default: begin
                wmask_comb    = 8'hFF;
                misalign_comb = 1'b0;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // Pipeline register - 1 cycle output
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            agu_valid_out      <= 1'b0;
            agu_is_store_out   <= 1'b0;
            agu_sq_idx_out     <= 4'h0;
            agu_addr_out       <= 64'h0;
            agu_data_out       <= 64'h0;
            agu_wmask_out      <= 8'h0;
            misalign_exception <= 1'b0;
            misalign_addr      <= 64'h0;
        end else begin
            // default: no valid output, no exception
            agu_valid_out      <= 1'b0;
            misalign_exception <= 1'b0;

            if (valid_in && uop_in.is_memory) begin
                if (misalign_comb) begin
                    misalign_exception <= 1'b1;
                    misalign_addr      <= computed_addr;
                end else begin
                    agu_valid_out    <= 1'b1;
                    agu_is_store_out <= is_store_comb;
                    agu_sq_idx_out   <= uop_in.sq_idx;
                    agu_addr_out     <= computed_addr;
                    agu_data_out     <= prf_store_data;
                    agu_wmask_out    <= wmask_comb;
                end
            end
        end
    end

endmodule