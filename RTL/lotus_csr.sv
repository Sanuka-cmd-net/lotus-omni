`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:       Lotus Omni (Fabless AI Semiconductor)
// Engineer:      Sanuka Nethmira Amarasekara
// Module Name:   lotus_csr
// Description:   Control and Status Register File - V1.0
//                RISC-V privileged spec compliant subset.
//                Supported CSRs:
//                  - mstatus, misa, mtvec, mepc, mcause, mtval
//                  - cycle, instret (from PMU)
//                  - Custom: tensor_ctrl, sparsity_ctrl, precision_mode
//////////////////////////////////////////////////////////////////////////////////

module lotus_csr import lotus_pkg::*; (
    input  logic clk,
    input  logic rst_n,

    // --- CSR INSTRUCTION INTERFACE ---
    input  logic [11:0] csr_addr,
    input  logic [1:0]  csr_op,      // 00=NOP, 01=WRITE, 10=SET, 11=CLEAR
    input  logic [63:0] csr_wdata,
    input  logic        csr_valid,
    input  logic        fence_instr,     // HIGH-014: FENCE instruction input
    input  logic        fence_i_instr,   // HIGH-014: FENCE.I instruction input
    output logic [63:0] csr_rdata,
    output logic        csr_illegal, // illegal CSR access
    output logic        fence_complete,     // HIGH-014: Signal when fence completes
    output logic        fence_i_complete,   // HIGH-014: Signal when fence.i completes

    // --- EXCEPTION INPUTS ---
    input  logic        exception_valid,
    input  logic [63:0] exception_pc,
    input  logic [63:0] exception_cause,
    input  logic [63:0] exception_tval,

    // --- EXCEPTION OUTPUTS (to IFU/ROB) ---
    output logic [63:0] mtvec_out,   // trap vector
    output logic [63:0] mepc_out,    // exception PC

    // --- CUSTOM CONTROL OUTPUTS ---
    output logic [1:0]  precision_mode, // 00=INT8, 01=BF16, 10=FP32
    output logic        sparsity_en,    // global sparsity enable
    output logic        tensor_en       // tensor core enable
);

    // -------------------------------------------------------------------------
    // Standard RISC-V Machine CSRs
    // -------------------------------------------------------------------------
    logic [63:0] mstatus;   // 0x300
    logic [63:0] misa;      // 0x301
    logic [63:0] mtvec;     // 0x305
    logic [63:0] mepc;      // 0x341
    logic [63:0] mcause;    // 0x342
    logic [63:0] mtval;     // 0x343
    logic [63:0] mhartid;   // 0xF14

    // -------------------------------------------------------------------------
    // Custom Lotus Omni CSRs
    // -------------------------------------------------------------------------
    logic [63:0] tensor_ctrl;   // 0x800 - [1:0]=precision, [2]=tensor_en
    logic [63:0] sparsity_ctrl; // 0x801 - [0]=sparsity_en, [7:4]=threshold

    // HIGH-014: FENCE/FENCE.I completion signals
    // MOVED BEFORE assign statements to fix elaboration order
    logic fence_pending;
    logic fence_i_pending;
    logic fence_complete_internal;
    logic fence_i_complete_internal;
    
    // Output registers to hold completion signals for at least one cycle
    logic fence_complete_reg;
    logic fence_i_complete_reg;

    // -------------------------------------------------------------------------
    // MISA - advertise supported extensions
    // RV64I + M + A + F + D + C + X(custom AI)
    // -------------------------------------------------------------------------
    localparam MISA_VAL = 64'h8000000000141105;

    // -------------------------------------------------------------------------
    // Assign outputs
    // -------------------------------------------------------------------------
    assign mtvec_out      = mtvec;
    assign mepc_out       = mepc;
    assign precision_mode = tensor_ctrl[1:0];
    assign tensor_en      = tensor_ctrl[2];
    assign sparsity_en    = sparsity_ctrl[0];
    assign fence_complete = fence_complete_reg;
    assign fence_i_complete = fence_i_complete_reg;

    // -------------------------------------------------------------------------
    // CSR Read
    // -------------------------------------------------------------------------
    always_comb begin
        csr_rdata   = 64'h0;
        csr_illegal = 1'b0;

        case (csr_addr)
            12'h300: csr_rdata = mstatus;
            12'h301: csr_rdata = MISA_VAL;
            12'h305: csr_rdata = mtvec;
            12'h341: csr_rdata = mepc;
            12'h342: csr_rdata = mcause;
            12'h343: csr_rdata = mtval;
            12'hF14: csr_rdata = mhartid;
            12'h800: csr_rdata = tensor_ctrl;
            12'h801: csr_rdata = sparsity_ctrl;
            // Custom FENCE CSRs (moved to standard custom range)
            12'h7C0: csr_rdata = {63'd0, fence_complete_reg};        // Custom FENCE CSR
            12'h7C1: csr_rdata = {63'd0, fence_i_complete_reg};      // Custom FENCE.I CSR
            default: begin
                csr_rdata   = 64'h0;
                csr_illegal = 1'b1;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // CSR Write
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstatus     <= 64'h0000_0000_0000_1800; // MPP=11 (M-mode)
            misa        <= MISA_VAL;
            mtvec       <= 64'h0000_0000_8000_0000; // default trap vector
            mepc        <= 64'h0;
            mcause      <= 64'h0;
            mtval       <= 64'h0;
            mhartid     <= 64'h0;
            tensor_ctrl <= 64'h0000_0000_0000_0005; // BF16 + tensor_en
            sparsity_ctrl <= 64'h0000_0000_0000_0001; // sparsity enabled
            // FENCE signals
            fence_pending <= 1'b0;
            fence_i_pending <= 1'b0;
            fence_complete_internal <= 1'b0;
            fence_i_complete_internal <= 1'b0;
            fence_complete_reg <= 1'b0;
            fence_i_complete_reg <= 1'b0;
        end else begin
            // Handle fence instructions
            if (fence_instr || fence_i_instr) begin
                fence_pending <= fence_instr;
                fence_i_pending <= fence_i_instr;
                fence_complete_internal <= 1'b0;
                fence_i_complete_internal <= 1'b0;
            end else begin
                // In a real implementation, this would wait for memory operations to complete
                // For simulation purposes, we'll assume fences complete immediately
                // In hardware, fence completion would depend on all prior memory ops completing
                if (fence_pending || fence_i_pending) begin
                    fence_complete_internal <= 1'b1;
                    fence_i_complete_internal <= 1'b1;
                    
                    // Clear pending flags after completion
                    if (fence_complete_internal && fence_i_complete_internal) begin
                        fence_pending <= 1'b0;
                        fence_i_pending <= 1'b0;
                    end
                end else begin
                    fence_complete_internal <= 1'b0;
                    fence_i_complete_internal <= 1'b0;
                end
            end
            
            // Update output registers for fence completion signals
            fence_complete_reg <= fence_complete_internal;
            fence_i_complete_reg <= fence_i_complete_internal;
            
            // Exception handling - auto-update CSRs
            if (exception_valid) begin
                mepc   <= exception_pc;
                mcause <= exception_cause;
                mtval  <= exception_tval;
            end

            // CSR instruction write
            if (csr_valid && !csr_illegal) begin
                case (csr_addr)
                    12'h300: begin
                        case (csr_op)
                            2'b01: mstatus <= csr_wdata;
                            2'b10: mstatus <= mstatus | csr_wdata;
                            2'b11: mstatus <= mstatus & ~csr_wdata;
                            default: ;
                        endcase
                    end
                    12'h305: begin
                        case (csr_op)
                            2'b01: mtvec <= csr_wdata;
                            2'b10: mtvec <= mtvec | csr_wdata;
                            2'b11: mtvec <= mtvec & ~csr_wdata;
                            default: ;
                        endcase
                    end
                    12'h341: begin
                        case (csr_op)
                            2'b01: mepc <= csr_wdata;
                            default: ;
                        endcase
                    end
                    12'h800: begin
                        case (csr_op)
                            2'b01: tensor_ctrl <= csr_wdata;
                            2'b10: tensor_ctrl <= tensor_ctrl | csr_wdata;
                            2'b11: tensor_ctrl <= tensor_ctrl & ~csr_wdata;
                            default: ;
                        endcase
                    end
                    12'h801: begin
                        case (csr_op)
                            2'b01: sparsity_ctrl <= csr_wdata;
                            2'b10: sparsity_ctrl <= sparsity_ctrl | csr_wdata;
                            2'b11: sparsity_ctrl <= sparsity_ctrl & ~csr_wdata;
                            default: ;
                        endcase
                    end
                    default: ;
                endcase
            end
        end
    end

endmodule
