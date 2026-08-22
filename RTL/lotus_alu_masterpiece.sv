`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:       Lotus Omni (Fabless AI Semiconductor)
// Engineer:      Sanuka Nethmira Amarasekara
// Module Name:   lotus_alu_masterpiece
// Description:   Tape-Out Ready 64-bit Simple ALU (Port 0) - V4.3 DEADLOCK FIX
//
// FIX ALU-LATCH-001 (preserved): word_result default assignment.
//
// FIX ASIC-TIMING-001 (preserved): Parallel OR-AND forwarding MUX.
//
// FIX ALU-TIMING-01 (V4.2): Input operand/control register stage (EX1 -> EX2).
//   Critical path was issue->forwarding-mux->64-bit-adder->output = 27 levels,
//   14.27ns (WNS -4.304ns). The forwarding/operand-select network (~8.8ns) and
//   the 64-bit adder (~2.9ns) were all combinational in ONE cycle before the
//   output register.
//   Fix: register the selected operands (src1/src2) + control at the ALU input.
//
// FIX ALU-DEADLOCK-001 (V4.3): 
//   1. Removed p_dest_q != 0 check in CDB writeback. Instructions targeting x0 
//      (e.g., NOPs) must return cdb_valid_out=1 so the ROB can commit them.
//   2. Changed '!=' to '!==' in opcode checks to prevent simulation 'X' propagation.
//////////////////////////////////////////////////////////////////////////////////

module lotus_alu_masterpiece import lotus_pkg::*; #(
    parameter EXEC_PORTS = 4 
)(
    input  logic clk, rst_n,
    input  logic flush,
    
    input  rs_entry_t uop_in,  
    input  logic      valid_in,
    
    input  logic [63:0] prf_src1_data,
    input  logic [63:0] prf_src2_data,
    
    input  logic [EXEC_PORTS-1:0][6:0]  cdb_p_dest_in, 
    input  logic [EXEC_PORTS-1:0][63:0] cdb_data_in,
    input  logic [EXEC_PORTS-1:0]       cdb_valid_in,
    
    output logic [6:0]  cdb_p_dest_out, 
    output logic [63:0] cdb_data_out,
    output logic        cdb_valid_out
);
    // ------------------------------------------------------------------------
    // 1. THE FORWARDING NETWORK (FIX ASIC-TIMING-001: Parallel OR-AND MUX)
    //    (combinational - feeds the NEW input register stage below)
    // ------------------------------------------------------------------------
    logic [63:0] src1_actual;
    logic [63:0] src2_actual;
    logic [EXEC_PORTS-1:0] src1_match;
    logic [EXEC_PORTS-1:0] src2_match;
    
    always_comb begin
        for (int i = 0; i < EXEC_PORTS; i++) begin
            src1_match[i] = cdb_valid_in[i] & (uop_in.p_src1 == cdb_p_dest_in[i]) & (uop_in.p_src1 != 7'h00);
            src2_match[i] = cdb_valid_in[i] & (uop_in.p_src2 == cdb_p_dest_in[i]) & (uop_in.p_src2 != 7'h00);
        end
        
        if (|src1_match) begin
            src1_actual = (src1_match[0] ? cdb_data_in[0] : 64'h0) |
                          (src1_match[1] ? cdb_data_in[1] : 64'h0) |
                          (src1_match[2] ? cdb_data_in[2] : 64'h0) |
                          (src1_match[3] ? cdb_data_in[3] : 64'h0);
        end else begin
            src1_actual = prf_src1_data;
        end

        if (|src2_match) begin
            src2_actual = (src2_match[0] ? cdb_data_in[0] : 64'h0) |
                          (src2_match[1] ? cdb_data_in[1] : 64'h0) |
                          (src2_match[2] ? cdb_data_in[2] : 64'h0) |
                          (src2_match[3] ? cdb_data_in[3] : 64'h0);
        end else begin
            src2_actual = prf_src2_data;
        end
    end

    // ------------------------------------------------------------------------
    // === FIX ALU-TIMING-01: INPUT OPERAND/CONTROL REGISTER (EX1 -> EX2) ===
    //    Breaks forwarding-mux -> adder chain. Operands + control latched here,
    //    computation happens next cycle from these registered values.
    // ------------------------------------------------------------------------
    logic [63:0] src1_q, src2_q;
    logic [63:0] imm_q, pc_q;
    logic [6:0]  opcode_q, p_dest_q, funct7_q;
    logic [2:0]  funct3_q;
    logic        valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            valid_q <= 1'b0;
        end else begin
            valid_q  <= valid_in;
            src1_q   <= src1_actual;
            src2_q   <= src2_actual;
            opcode_q <= uop_in.opcode;
            funct3_q <= uop_in.funct3;
            funct7_q <= uop_in.funct7;
            imm_q    <= uop_in.imm_data;
            pc_q     <= uop_in.pc;
            p_dest_q <= uop_in.p_dest;
        end
    end

    // ------------------------------------------------------------------------
    // 2. OPERAND SELECTION & FULL RV64I ALU EXECUTION
    //    (now computed from REGISTERED operands src1_q/src2_q/ctrl_q)
    // ------------------------------------------------------------------------
    logic [63:0] alu_result;
    logic [63:0] op2_mux; 
    logic [5:0]  shamt;
    logic [2:0]  func3;
    logic        is_sub_sra;
    logic [31:0] word_result;

    always_comb begin
        alu_result  = 64'h0;
        word_result = 32'h0;   // FIX ALU-LATCH-001: default prevents latch

        if (opcode_q == 7'b0010011 || opcode_q == 7'b0000011 ||
            opcode_q == 7'b1100111 || opcode_q == 7'b0100011) begin
            op2_mux = imm_q;
        end else begin
            op2_mux = src2_q;
        end

        shamt      = op2_mux[5:0]; 
        func3      = funct3_q;
        is_sub_sra = funct7_q[5];

        case (opcode_q)
            7'b0110011, 7'b0010011: begin 
                case (func3)
                    3'b000: alu_result = (is_sub_sra && opcode_q == 7'b0110011) ? (src1_q - op2_mux) : (src1_q + op2_mux); 
                    3'b001: alu_result = src1_q << shamt;
                    3'b010: alu_result = ($signed(src1_q) < $signed(op2_mux)) ? 64'h1 : 64'h0;  
                    3'b011: alu_result = (src1_q < op2_mux) ? 64'h1 : 64'h0;
                    3'b100: alu_result = src1_q ^ op2_mux;                                      
                    3'b101: alu_result = (is_sub_sra) ? ($signed(src1_q) >>> shamt) : (src1_q >> shamt);
                    3'b110: alu_result = src1_q | op2_mux;                                      
                    3'b111: alu_result = src1_q & op2_mux;                                      
                    default: alu_result = 64'h0;
                endcase
            end
            
            7'b0111011, 7'b0011011: begin  
                case (func3)
                    3'b000: word_result = (is_sub_sra && opcode_q == 7'b0111011) ? (src1_q[31:0] - op2_mux[31:0]) : (src1_q[31:0] + op2_mux[31:0]); 
                    3'b001: word_result = src1_q[31:0] << shamt[4:0];                                       
                    3'b101: word_result = (is_sub_sra) ? ($signed(src1_q[31:0]) >>> shamt[4:0]) : (src1_q[31:0] >> shamt[4:0]); 
                    default: word_result = 32'h0;
                endcase
                alu_result = {{32{word_result[31]}}, word_result};
            end
             
            7'b0110111: alu_result = imm_q;
            7'b0010111: alu_result = pc_q + imm_q;
            
            default: alu_result = 64'h0;
        endcase
    end

    // ------------------------------------------------------------------------
    // 3. PIPELINED OUTPUT TO CDB (uses registered valid_q/p_dest_q/opcode_q)
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            cdb_valid_out  <= 1'b0;
            cdb_p_dest_out <= 7'h00;
            cdb_data_out   <= 64'h0;
        end else begin
            // FIX ALU-DEADLOCK-001 (V4.3):
            // 1. Use !== to prevent simulation 'X' propagation from failing the condition.
            if (valid_q && opcode_q !== 7'b0100011 &&  
                           opcode_q !== 7'b0000011 &&  
                           opcode_q !== 7'b1101111 &&  
                           opcode_q !== 7'b1100111) begin 
                
                // 2. Removed the (p_dest_q != 7'h00) check. 
                // Instructions writing to x0 MUST return valid so ROB can commit them.
                cdb_valid_out  <= 1'b1;
                cdb_p_dest_out <= p_dest_q;
                cdb_data_out   <= alu_result;
                
            end else begin
                cdb_valid_out  <= 1'b0;
                cdb_p_dest_out <= 7'h00;
                cdb_data_out   <= 64'h0;
            end
        end
    end

endmodule