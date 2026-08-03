// =========================================
// File Name: lotus_pkg.sv
// =========================================
`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// Company:       Lotus Omni (Fabless AI Semiconductor)
// Engineer:      Sanuka Nethmira Amarasekara
// Module Name:   lotus_pkg - V6.1 (Artix-7 xc7a200t Optimized)
// Description:   Complete type definitions for Lotus Omni AI Accelerator
//                OPTIMIZED: Parameters tuned for Artix-7 134K LUT budget
//                Target: ~90K-100K LUTs (comfortably under 134K limit)
//
// FIX PKG-PRF-001: PRF_ENTRIES corrected from 64 to 128 to match the
//   Renamer's PHYS_REGS=128 and lotus_omni_core_top_v2's PRF_ENTRIES=128
//   parameter. Previously the pkg localparam was 64 while every
//   instantiation overrode it to 128, creating a silent mismatch that
//   could confuse any tool or script reading the package for sizing.
////////////////////////////////////////////////////////////////////////////////
package lotus_pkg;
    localparam ADDR_WIDTH = 64;
    localparam DATA_WIDTH = 64;
    localparam CORD_WIDTH = 4;

    // =========================================================================
    // Architecture Parameters - Artix-7 Optimized
    // Original Blackwell-class → Scaled for xc7a200t (134,600 LUTs)
    // =========================================================================
    localparam ROB_ENTRIES      = 32;   // Was 128 → 32  (~25K LUT save)
    localparam PRF_ENTRIES      = 128;  // FIX PKG-PRF-001: Was 64 → 128 (aligned with Renamer PHYS_REGS)
    localparam RS_DEPTH         = 16;   // Was 64  → 16  (~18K LUT save)
    localparam SQ_DEPTH         = 8;    // Was 16  → 8   (~3K LUT save)
    localparam NUM_TENSOR_PORTS = 4;    // Kept same

    // =========================================================================
    // Cache Parameters - Artix-7 Optimized
    // =========================================================================
    localparam OFFSET_BITS = 6;         // 64-byte line size (kept same)
    localparam INDEX_BITS  = 6;         // Was 9 (512 sets) → 6 (64 sets) (~20K LUT save)
    localparam NUM_LINES   = 64;        // Was 512 → 64

    // =========================================================================
    // Derived - ROB index width (used in rob_idx fields)
    // ROB_ENTRIES=32 → 5 bits needed
    // NOTE: All rob_idx fields in structs below use [6:0] (7 bits) for
    //       forward compatibility. Synthesizer will trim unused bits.
    // =========================================================================

    // 1. FETCH & DECODE
    typedef struct packed {
        logic [511:0] inst_block;      // 16 × 32-bit instructions
        logic [63:0]  pc;
        logic         pred_taken;
        logic [63:0]  pred_target;
        logic [15:0]  valid_mask;
    } fetch_packet_t;

    typedef struct packed {
        logic [63:0]  pc;
        logic [7:0]   opcode;
        logic [6:0]   dest_reg;
        logic [6:0]   src1_reg;
        logic [6:0]   src2_reg;
        logic [63:0]  imm_data;
        logic [2:0]   funct3;
        logic [6:0]   funct7;
        logic         is_tensor_op;
        logic [1:0]   precision;       // 00=INT8, 01=BF16, 10=FP32
        logic         is_branch;
        logic         is_memory;
        logic         is_illegal;
        logic         is_csr;
        logic         valid;
    } uop_t;

    // 2. RENAMER OUTPUT
    typedef struct packed {
        logic [63:0]  pc;
        logic [7:0]   opcode;
        logic [6:0]   p_dest;
        logic [6:0]   p_src1;
        logic [6:0]   p_src2;
        logic [6:0]   p_old_dest;
        logic [63:0]  imm_data;
        logic [2:0]   funct3;
        logic [6:0]   funct7;
        logic         is_tensor_op;
        logic [1:0]   precision;
        logic         is_branch;
        logic         is_memory;
        logic         is_illegal;
        logic         is_csr;
        logic         valid;
    } renamed_uop_t;

    // 3. RESERVATION STATION ENTRY
    typedef struct packed {
        logic        valid;
        logic [6:0]  rob_idx;
        logic [4:0]  sq_idx;
        logic [63:0] pc;
        logic [7:0]  opcode;
        logic [6:0]  p_dest;
        logic [6:0]  p_src1;
        logic [6:0]  p_src2;
        logic [63:0] imm_data;
        logic [2:0]  funct3;
        logic [6:0]  funct7;
        logic        is_tensor_op;
        logic [1:0]  precision;
        logic        is_branch;
        logic        is_memory;
        logic        is_csr;
        logic [2:0]  branch_tag;
        logic [23:0] age;
        logic        pred_taken;
        logic [63:0] pred_target;
    } rs_entry_t;

    // 4. REORDER BUFFER ENTRY
    typedef struct packed {
        logic        valid;
        logic        completed;
        logic [63:0] pc;
        logic [6:0]  p_dest;
        logic [6:0]  p_old_dest;
        logic        is_branch;
        logic        is_memory;
        logic        is_store;
        logic [4:0]  lsq_idx;
        logic        exception_valid;
        logic [63:0] exception_cause;
        logic [2:0]  branch_tag;
    } rob_entry_t;

    // 5. CACHE & LSQ
    typedef struct packed {
        logic [ADDR_WIDTH-OFFSET_BITS-INDEX_BITS-1:0] tag;
        logic [INDEX_BITS-1:0]                         index;
        logic [OFFSET_BITS-1:0]                        offset;
    } cache_addr_t;

    typedef struct packed {
        logic        valid;
        logic        dirty;
        logic [ADDR_WIDTH-OFFSET_BITS-INDEX_BITS-1:0] tag;
    } tag_entry_t;

    typedef struct packed {
        logic        valid;
        logic        addr_valid;
        logic        data_valid;
        logic        committed;
        logic [6:0]  rob_idx;
        logic [63:0] addr;
        logic [63:0] data;
        logic [7:0]  wmask;
    } sq_entry_t;

    // 6. NOC ROUTER & SPARSITY
    typedef struct packed {
        logic [1:0]  flit_type;        // 00=HEAD, 01=BODY, 10=TAIL, 11=SINGLE
        logic [3:0]  dest_x;
        logic [3:0]  dest_y;
        logic [63:0] payload;
    } flit_t;

    typedef struct packed {
        logic [7:0]      mask;
        logic [3:0]      nz_count;
        logic [7:0][7:0] packed_data;
    } sparse_packet_t;

    // 7. CDB (Common Data Bus) ENTRY
    typedef struct packed {
        logic        valid;
        logic [6:0]  p_dest;
        logic [63:0] data;
        logic        exception;
        logic [63:0] exc_cause;
    } cdb_entry_t;

    // 8. TENSOR OPERATION DESCRIPTOR
    typedef struct packed {
        logic [15:0]     rows;
        logic [15:0]     cols;
        logic [15:0]     k_dim;
        logic [1:0]      precision;
        logic            sparse_en;
        logic [63:0]     a_addr;
        logic [63:0]     b_addr;
        logic [63:0]     c_addr;
    } tensor_desc_t;

    // 9. BRANCH PREDICTION STATE (TAGE-class)
    typedef struct packed {
        logic        valid;
        logic [9:0]  tag;
        logic [2:0]  ctr;
    } tage_entry_t;

    // 10. BTB ENTRY
    typedef struct packed {
        logic        valid;
        logic [63:0] pc;
        logic [63:0] target;
        logic [3:0]  taken_count;
    } btb_entry_t;

endpackage