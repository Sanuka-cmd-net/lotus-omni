`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:       Lotus Omni (Fabless AI Semiconductor)
// Engineer:      Sanuka Nethmira Amarasekara
// Module Name:   lotus_branch_exec - V2.0 FIXED
//
// FIX HIGH-001: branch_tag_out was HARDCODED to 0
//   OLD: assign branch_tag_out = 3'h0;   // ← Bug! All checkpoints used slot 0
//   NEW: branch_tag_out properly registered from RS entry's branch_tag field
//        This allows MAX_BR=8 independent speculative checkpoints
//
// FIX CRIT-004 (partial): This module now drives flush_branch_tag correctly
//   Top-level must connect:
//     branch_exec_tag  → renamer's flush_branch_tag
//     branch_flush_en  → renamer's flush_en
//
// Architecture:
//   - RISC-V RV64I branch resolution
//   - JAL/JALR link address = PC+4
//   - Conditional branches: BEQ/BNE/BLT/BGE/BLTU/BGEU
//   - CDB broadcast on resolution
//////////////////////////////////////////////////////////////////////////////////

module lotus_branch_exec import lotus_pkg::*; (
    input  logic clk,
    input  logic rst_n,

    // --- INPUT FROM RS (issue) ---
    input  logic        issue_valid,
    input  logic [63:0] issue_pc,
    input  logic [7:0]  issue_opcode,
    input  logic [2:0]  issue_funct3,    // FIXED: funct3 passed separately
    input  logic [63:0] issue_src1,        // rs1 value (from PRF)
    input  logic [63:0] issue_src2,        // rs2 value (from PRF)
    input  logic [63:0] issue_imm,         // branch offset / jump target
    input  logic [6:0]  issue_p_dest,      // physical dest (for JAL/JALR)
    input  logic        issue_pred_taken,  // predictor's prediction
    input  logic [63:0] issue_pred_target, // predictor's target
    input  logic [2:0]  issue_branch_tag,  // FIXED: now taken from RS entry

    // --- CDB OUTPUT ---
    output logic        cdb_valid,
    output logic [6:0]  cdb_p_dest,
    output logic [63:0] cdb_data,          // link address for JAL/JALR, 0 for branches

    // --- BRANCH RESOLUTION OUTPUT ---
    output logic        branch_resolved,
    output logic        branch_correct_pc_valid,
    output logic [63:0] branch_correct_pc,
    output logic        branch_mispredict,
    output logic [2:0]  branch_tag_out,    // FIXED: was hardcoded 0, now proper tag

    // --- PERF ---
    output logic        perf_mispredict
);

    // =========================================================================
    // Opcode definitions (RV64I encoding - 7-bit values)
    // =========================================================================
    localparam [6:0] OP_JAL    = 7'h6F;
    localparam [6:0] OP_JALR   = 7'h67;
    localparam [6:0] OP_BRANCH = 7'h63;

    // Branch funct3
    localparam F3_BEQ  = 3'b000;
    localparam F3_BNE  = 3'b001;
    localparam F3_BLT  = 3'b100;
    localparam F3_BGE  = 3'b101;
    localparam F3_BLTU = 3'b110;
    localparam F3_BGEU = 3'b111;

    // =========================================================================
    // Combinational branch outcome
    // =========================================================================
    logic        br_taken_comb;
    logic [63:0] br_target_comb;
    logic [63:0] link_addr;

    always_comb begin
        br_taken_comb  = 1'b0;
        br_target_comb = 64'h0;
        link_addr      = issue_pc + 64'd4;

        case (issue_opcode[6:0])
            OP_JAL: begin
                // JAL: target = PC + imm (already sign-extended J-type)
                br_taken_comb  = 1'b1;
                br_target_comb = issue_pc + issue_imm;
            end

            OP_JALR: begin
                // JALR: target = (rs1 + imm) & ~1
                br_taken_comb  = 1'b1;
                br_target_comb = (issue_src1 + issue_imm) & ~64'h1;
            end

            OP_BRANCH: begin
                // Conditional branch: target = PC + imm
                br_target_comb = issue_pc + issue_imm;
                case (issue_funct3)  // FIXED: use dedicated funct3 input
                    F3_BEQ:  br_taken_comb = (issue_src1 == issue_src2);
                    F3_BNE:  br_taken_comb = (issue_src1 != issue_src2);
                    F3_BLT:  br_taken_comb = ($signed(issue_src1) <  $signed(issue_src2));
                    F3_BGE:  br_taken_comb = ($signed(issue_src1) >= $signed(issue_src2));
                    F3_BLTU: br_taken_comb = (issue_src1 <  issue_src2);
                    F3_BGEU: br_taken_comb = (issue_src1 >= issue_src2);
                    default: br_taken_comb = 1'b0;
                endcase
            end

            default: begin
                br_taken_comb  = 1'b0;
                br_target_comb = issue_pc + 64'd4;
            end
        endcase
    end

    // =========================================================================
    // Registered outputs
    // =========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cdb_valid             <= 1'b0;
            cdb_p_dest            <= 7'h0;
            cdb_data              <= 64'h0;
            branch_resolved       <= 1'b0;
            branch_correct_pc_valid <= 1'b0;
            branch_correct_pc     <= 64'h0;
            branch_mispredict     <= 1'b0;
            branch_tag_out        <= 3'h0;
            perf_mispredict       <= 1'b0;
        end else begin
            // Defaults
            cdb_valid             <= 1'b0;
            branch_resolved       <= 1'b0;
            branch_mispredict     <= 1'b0;
            branch_correct_pc_valid <= 1'b0;
            perf_mispredict       <= 1'b0;

            if (issue_valid) begin
                // -------------------------------------------------------
                // CDB: JAL/JALR write link address to dest register
                // -------------------------------------------------------
                if (issue_opcode == OP_JAL || issue_opcode == OP_JALR) begin
                    cdb_valid  <= 1'b1;
                    cdb_p_dest <= issue_p_dest;
                    cdb_data   <= link_addr;   // Return address = PC+4
                end

                // -------------------------------------------------------
                // Carry branch_tag from the RS entry every cycle
                // -------------------------------------------------------
                branch_resolved <= 1'b1;

                // -------------------------------------------------------
                // Misprediction detection
                // -------------------------------------------------------
                if (br_taken_comb != issue_pred_taken ||
                    (br_taken_comb && br_target_comb != issue_pred_target)) begin
                    // Mispredicted
                    branch_mispredict         <= 1'b1;
                    branch_correct_pc_valid   <= 1'b1;
                    branch_correct_pc         <= br_taken_comb ?
                                                  br_target_comb :
                                                  (issue_pc + 64'd4);
                    perf_mispredict           <= 1'b1;
                end

                // -------------------------------------------------------
                // Update branch_tag_out only when there's a valid issue
                // -------------------------------------------------------
                branch_tag_out <= issue_branch_tag;
            end
        end
    end
endmodule