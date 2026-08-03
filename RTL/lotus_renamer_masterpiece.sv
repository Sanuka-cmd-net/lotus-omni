`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// lotus_renamer_masterpiece - V3.3 TIMING OPTIMIZED
// Engineer:      Sanuka Nethmira Amarasekara (Lotus Omni)
// Target:        Xilinx Artix-7 xc7a200t
//
// FIX REN-TIMING-02 (V3.3): Output pipeline register.
//   Critical path: dispatch_uop.dest_reg → alloc_preg (128-entry free list
//   MUX) → out_uop.p_dest → PRF prf_ready_bits update.
//   13 logic levels, 13.15ns, WNS -3.184ns.
//
//   Fix: Register out_uop, out_valid, out_p_old_dest at renamer output.
//   Cuts the deep alloc_preg → prf_ready_bits path at the renamer boundary.
//   Adds 1 cycle dispatch latency (functionally safe - pipeline stage).
//   rename_ready and free_list_count remain combinational (status signals).
//
// Previous fixes preserved:
//   FIX REN-003: Complete free_list reset initialization.
//   FIX REN-004: free_list value wrap-around (skip 0).
//   FIX REN-005: Synchronous reset (no async recovery violation).
//   FIX REN-TIMING-01 (V3.2): Shallow allocation/count logic.
//////////////////////////////////////////////////////////////////////////////////

module lotus_renamer_masterpiece import lotus_pkg::*; #(
    parameter PHYS_REGS = 128,
    parameter ARCH_REGS = 32,
    parameter MAX_BR    = 8
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,
    input  logic        flush_branch_valid,
    input  logic [2:0]  flush_branch_tag,
    input  logic        save_checkpoint,
    input  logic [2:0]  save_branch_tag,
    input  uop_t        in_uop   [0:3],
    input  logic [3:0]  in_valid,
    output renamed_uop_t out_uop  [0:3],       // FIX REN-TIMING-02: now registered
    output logic [3:0]   out_valid,             // FIX REN-TIMING-02: now registered
    output logic         rename_ready,
    output logic [6:0]   out_p_old_dest [0:3],  // FIX REN-TIMING-02: now registered
    output logic [7:0]   free_list_count,
    input  logic [3:0]   commit_valid,
    input  logic [6:0]   commit_p_old_dest [0:3]
);

    localparam FL_DEPTH = PHYS_REGS;

    logic [6:0] rat_table        [0:ARCH_REGS-1];
    logic [6:0] rat_checkpoint   [0:MAX_BR-1][0:ARCH_REGS-1];
    logic [6:0] free_list        [0:FL_DEPTH-1];
    logic [7:0] fl_count_checkpoint [0:MAX_BR-1];
    logic [6:0] fl_head, fl_tail;
    logic [6:0] fl_head_checkpoint [0:MAX_BR-1];
    logic [6:0] fl_tail_checkpoint [0:MAX_BR-1];
    logic [7:0] fl_count;
    logic [7:0] branch_in_flight [0:MAX_BR-1];

    assign free_list_count = fl_count;
    assign rename_ready    = (fl_count >= 4);

    // =========================================================================
    // FIX REN-TIMING-01: SHALLOW allocation / commit counts
    // =========================================================================
    logic [2:0] n_alloc, n_commit;
    always_comb begin
        n_alloc = 3'h0;
        for (int i = 0; i < 4; i++)
            if (in_valid[i] && in_uop[i].dest_reg != 7'h0)
                n_alloc = n_alloc + 1;

        n_commit = 3'h0;
        for (int i = 0; i < 4; i++)
            if (commit_valid[i] && commit_p_old_dest[i] != 7'h0)
                n_commit = n_commit + 1;
    end

    // =========================================================================
    // Combinational: allocate physical registers (data path - deep, but only
    // feeds p_dest DATA, not the count logic).
    // =========================================================================
    logic [6:0] alloc_preg       [0:3];
    logic [6:0] alloc_count_comb;

    always_comb begin
        alloc_count_comb = 7'h0;
        for (int i = 0; i < 4; i++) begin
            if (in_valid[i] && in_uop[i].dest_reg != 7'h0) begin
                alloc_preg[i]    = free_list[(fl_head + alloc_count_comb) & (FL_DEPTH-1)];
                alloc_count_comb = alloc_count_comb + 1;
            end else begin
                alloc_preg[i] = 7'h0;
            end
        end
    end

    // =========================================================================
    // FIX REN-TIMING-02: Internal combinational outputs (before pipeline reg)
    // =========================================================================
    renamed_uop_t out_uop_comb  [0:3];
    logic [3:0]   out_valid_comb;
    logic [6:0]   out_p_old_dest_comb [0:3];

    // =========================================================================
    // Combinational: rename
    // =========================================================================
    always_comb begin
        for (int i = 0; i < 4; i++) begin
            out_uop_comb[i]        = '0;
            out_valid_comb[i]      = 1'b0;
            out_p_old_dest_comb[i] = '0;

            if (in_valid[i]) begin
                out_valid_comb[i]              = 1'b1;
                out_uop_comb[i].pc            = in_uop[i].pc;
                out_uop_comb[i].opcode        = in_uop[i].opcode;
                out_uop_comb[i].imm_data      = in_uop[i].imm_data;
                out_uop_comb[i].is_tensor_op  = in_uop[i].is_tensor_op;
                out_uop_comb[i].precision     = in_uop[i].precision;
                out_uop_comb[i].is_branch     = in_uop[i].is_branch;
                out_uop_comb[i].is_memory     = in_uop[i].is_memory;
                out_uop_comb[i].is_illegal    = in_uop[i].is_illegal;
                out_uop_comb[i].is_csr        = in_uop[i].is_csr;
                out_uop_comb[i].funct3        = in_uop[i].funct3;
                out_uop_comb[i].funct7        = in_uop[i].funct7;
                out_uop_comb[i].p_dest        = (in_uop[i].dest_reg != 7'h0) ?
                                                 alloc_preg[i] : 7'h0;
                out_uop_comb[i].p_old_dest    = rat_table[in_uop[i].dest_reg[4:0]];
                out_p_old_dest_comb[i]        = out_uop_comb[i].p_old_dest;
                out_uop_comb[i].p_src1        = rat_table[in_uop[i].src1_reg[4:0]];
                out_uop_comb[i].p_src2        = rat_table[in_uop[i].src2_reg[4:0]];

                // Intra-bundle forwarding
                for (int j = 0; j < i; j++) begin
                    if (in_valid[j] && out_valid_comb[j] &&
                        in_uop[j].dest_reg != 7'h0) begin
                        if (in_uop[j].dest_reg == in_uop[i].src1_reg)
                            out_uop_comb[i].p_src1 = alloc_preg[j];
                        if (in_uop[j].dest_reg == in_uop[i].src2_reg)
                            out_uop_comb[i].p_src2 = alloc_preg[j];
                    end
                end
            end
        end
    end

    // =========================================================================
    // Combinational: next RAT
    // =========================================================================
    logic [6:0] next_rat [0:ARCH_REGS-1];
    always_comb begin
        for (int r = 0; r < ARCH_REGS; r++) next_rat[r] = rat_table[r];
        for (int i = 3; i >= 0; i--) begin
            if (in_valid[i] && in_uop[i].dest_reg != 7'h0)
                next_rat[in_uop[i].dest_reg[4:0]] = out_uop_comb[i].p_dest;
        end
    end

    // =========================================================================
    // Combinational: next free list
    // =========================================================================
    logic [6:0] next_free_list [0:FL_DEPTH-1];
    logic [6:0] next_fl_head, next_fl_tail;
    logic [7:0] next_fl_count;

    always_comb begin
        logic [2:0] commit_offset;
        for (int i = 0; i < FL_DEPTH; i++) next_free_list[i] = free_list[i];

        commit_offset = 3'h0;
        for (int i = 0; i < 4; i++) begin
            if (commit_valid[i] && commit_p_old_dest[i] != 7'h0) begin
                next_free_list[(fl_tail + commit_offset) & (FL_DEPTH-1)] = commit_p_old_dest[i];
                commit_offset = commit_offset + 1;
            end
        end

        next_fl_head  = (fl_head + n_alloc)  & (FL_DEPTH-1);
        next_fl_tail  = (fl_tail + n_commit) & (FL_DEPTH-1);
        next_fl_count = (fl_count + n_commit >= n_alloc) ?
                        (fl_count + n_commit - n_alloc) : 8'h0;
    end

    // =========================================================================
    // Combinational: next checkpoints
    // =========================================================================
    logic [6:0] next_fl_head_checkpoint  [0:MAX_BR-1];
    logic [6:0] next_fl_tail_checkpoint  [0:MAX_BR-1];
    logic [7:0] next_fl_count_checkpoint [0:MAX_BR-1];
    logic [6:0] next_rat_checkpoint      [0:MAX_BR-1][0:ARCH_REGS-1];
    logic [7:0] next_branch_in_flight    [0:MAX_BR-1];

    always_comb begin
        for (int b = 0; b < MAX_BR; b++) begin
            next_fl_head_checkpoint[b]  = fl_head_checkpoint[b];
            next_fl_tail_checkpoint[b]  = fl_tail_checkpoint[b];
            next_fl_count_checkpoint[b] = fl_count_checkpoint[b];
            next_branch_in_flight[b]    = branch_in_flight[b];
            for (int r = 0; r < ARCH_REGS; r++)
                next_rat_checkpoint[b][r] = rat_checkpoint[b][r];
        end
        if (save_checkpoint) begin
            for (int r = 0; r < ARCH_REGS; r++)
                next_rat_checkpoint[save_branch_tag][r] = rat_table[r];
            next_fl_head_checkpoint[save_branch_tag]  = fl_head;
            next_fl_count_checkpoint[save_branch_tag] = fl_count;
            next_fl_tail_checkpoint[save_branch_tag]  = fl_tail;
            next_branch_in_flight[save_branch_tag]    =
                branch_in_flight[save_branch_tag] + 1;
        end
    end

    // =========================================================================
    // Sequential: internal state
    // FIX REN-005: Synchronous Reset (preserved)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int r = 0; r < ARCH_REGS; r++) rat_table[r] <= 7'(r);
            for (int f = 0; f < FL_DEPTH; f++) begin
                if ((ARCH_REGS + f) < PHYS_REGS)
                    free_list[f] <= 7'(ARCH_REGS + f);
                else
                    free_list[f] <= 7'((ARCH_REGS + f) % PHYS_REGS);
            end
            fl_head  <= 7'(0);
            fl_tail  <= 7'(PHYS_REGS - ARCH_REGS);
            fl_count <= 8'(PHYS_REGS - ARCH_REGS);
            for (int b = 0; b < MAX_BR; b++) begin
                fl_head_checkpoint[b]  <= 7'(0);
                fl_count_checkpoint[b] <= 8'(PHYS_REGS - ARCH_REGS);
                fl_tail_checkpoint[b]  <= 7'(PHYS_REGS - ARCH_REGS);
                for (int r = 0; r < ARCH_REGS; r++)
                    rat_checkpoint[b][r] <= 7'(r);
                branch_in_flight[b] <= 8'h0;
            end
        end else begin
            if (flush && flush_branch_valid) begin
                for (int r = 0; r < ARCH_REGS; r++)
                    rat_table[r] <= rat_checkpoint[flush_branch_tag][r];
                fl_head  <= fl_head_checkpoint[flush_branch_tag];
                fl_count <= fl_count_checkpoint[flush_branch_tag];
                fl_tail  <= fl_tail_checkpoint[flush_branch_tag];
                for (int b = 0; b < MAX_BR; b++)
                    branch_in_flight[b] <= 8'h0;
            end else begin
                for (int r = 0; r < ARCH_REGS; r++)
                    rat_table[r] <= next_rat[r];
                for (int i = 0; i < FL_DEPTH; i++)
                    free_list[i] <= next_free_list[i];
                fl_head  <= next_fl_head;
                fl_tail  <= next_fl_tail;
                fl_count <= next_fl_count;
                for (int b = 0; b < MAX_BR; b++) begin
                    fl_head_checkpoint[b]  <= next_fl_head_checkpoint[b];
                    fl_tail_checkpoint[b]  <= next_fl_tail_checkpoint[b];
                    fl_count_checkpoint[b] <= next_fl_count_checkpoint[b];
                    branch_in_flight[b]    <= next_branch_in_flight[b];
                    for (int r = 0; r < ARCH_REGS; r++)
                        rat_checkpoint[b][r] <= next_rat_checkpoint[b][r];
                end
            end
        end
    end

    // =========================================================================
    // FIX REN-TIMING-02: Output pipeline register
    //   Cuts the deep alloc_preg → prf_ready_bits path at renamer boundary.
    //   Adds 1 cycle dispatch latency (functionally safe - pipeline stage).
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n || flush) begin
            for (int i = 0; i < 4; i++) begin
                out_uop[i]        <= '0;
                out_p_old_dest[i] <= '0;
            end
            out_valid <= 4'h0;
        end else begin
            for (int i = 0; i < 4; i++) begin
                out_uop[i]        <= out_uop_comb[i];
                out_p_old_dest[i] <= out_p_old_dest_comb[i];
            end
            out_valid <= out_valid_comb;
        end
    end

endmodule