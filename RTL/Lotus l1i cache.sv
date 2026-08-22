`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:       Lotus Omni (Fabless AI Semiconductor)
// Engineer:      Sanuka Nethmira Amarasekara
// Module Name:   lotus_l1i_cache - V4.2 SIMULATION X-STATE FIX
//
// FIX APPLIED:
//   - SYNTH-8-324: Changed array declarations from [NUM_SETS-1] to [0:NUM_SETS-1]
//     (In SV, [511] means 1 element at index 511. [0:511] means 512 elements)
//   - V4.2 SIMULATION FIX: Added initial block to initialize BRAM arrays
//     to 0 at simulation start. This prevents X-state propagation in XSim
//     while preserving proper BRAM inference for synthesis.
//
// Architecture: (100% PRESERVED)
//   - 512-set direct-mapped instruction cache
//   - 64-byte (512-bit) cache lines
//   - BRAM data + tag arrays (NO RESET on SRAM)
//   - Separate valid_bits array (flip-flops, resettable)
//   - 5-state FSM: IDLE → READ_RAM → READ_REG → COMPARE → ALLOCATE
//////////////////////////////////////////////////////////////////////////////////

module lotus_l1i_cache #(
    parameter ADDR_WIDTH = 64,
    parameter LINE_SIZE  = 512,
    parameter NUM_SETS   = 512
)(
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  cpu_req_valid,
    input  logic [ADDR_WIDTH-1:0] cpu_req_pc,
    output logic                  cpu_req_ready,
    output logic                  cpu_resp_valid,
    output logic [LINE_SIZE-1:0]  cpu_resp_data,
    output logic                  cpu_resp_hit,

    output logic                  mem_req_valid,
    output logic [ADDR_WIDTH-1:0] mem_req_addr,
    input  logic                  mem_req_ready,
    input  logic                  mem_resp_valid,
    input  logic [LINE_SIZE-1:0]  mem_resp_data
);

    localparam OFFSET_BITS = 6;
    localparam INDEX_BITS  = $clog2(NUM_SETS);   // 9 bits for 512 sets
    localparam TAG_BITS    = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS;  // 49 bits

    // =========================================================================
    // ASIC REALITY CHECK: SRAM Reset Behavior
    // =========================================================================
    // Hardware SRAM cells (6T, 8T, DFFF) CANNOT be reset in a single cycle.
    // A for-loop reset like: for(i=0; i<512; i++) tag_ram[i] <= '0;
    // causes synthesis tools to REJECT SRAM inference and implement the entire
    // cache as flip-flops - massive area and power waste.
    //
    // SOLUTION: 
    //   - Tag/Data RAMs: NO RESET (proper SRAM inference)
    //   - Valid bits: Separate flip-flop array (CAN be reset)
    //   - On reset: Only clear valid_bits, tags are "don't care" until valid=1
    // =========================================================================

    // 🛠️ SENIOR FIX: Changed [NUM_SETS-1] to [0:NUM_SETS-1] for proper 512-element array sizing
    // Tag RAM - NO RESET to allow proper SRAM inference
    (* ram_style = "block" *) logic [TAG_BITS-1:0]   tag_ram  [0:NUM_SETS-1];
    
    // Data RAM - NO RESET to allow proper SRAM inference
    (* ram_style = "block" *) logic [LINE_SIZE-1:0]  data_ram [0:NUM_SETS-1];

    // Valid bits - implemented as flip-flops, CAN be bulk reset
    logic valid_bits [0:NUM_SETS-1];

    // =========================================================================
    // FSM
    // =========================================================================
    typedef enum logic [2:0] {
        IDLE     = 3'b000,
        READ_RAM = 3'b001,
        READ_REG = 3'b010,   // Absorb BRAM output register latency
        COMPARE  = 3'b011,
        ALLOCATE = 3'b100
    } state_t;

    state_t state;

    logic [ADDR_WIDTH-1:0] addr_q;
    logic [INDEX_BITS-1:0] addr_index;
    logic [TAG_BITS-1:0]   addr_tag;

    assign addr_index = addr_q[INDEX_BITS+OFFSET_BITS-1 : OFFSET_BITS];
    assign addr_tag   = addr_q[ADDR_WIDTH-1 : INDEX_BITS+OFFSET_BITS];

    // BRAM read outputs - stage 1 (raw BRAM output)
    logic [TAG_BITS-1:0]   tag_bram_out;
    logic [LINE_SIZE-1:0]  data_bram_out;
    logic                  valid_bram_out;

    // BRAM read outputs - stage 2 (output register, merged into BRAM by tools)
    (* shreg_extract = "no" *) logic [TAG_BITS-1:0]   tag_read_q;
    (* shreg_extract = "no" *) logic [LINE_SIZE-1:0]  data_read_q;
    (* shreg_extract = "no" *) logic                  valid_read_q;

    // Hit detection: valid_bit AND tag match
    wire is_hit = valid_read_q && (tag_read_q == addr_tag);

    // Tag/data write signals
    logic                  tag_we;
    logic [INDEX_BITS-1:0] tag_waddr;
    logic [TAG_BITS-1:0]   tag_wdata;
    logic                  data_we;
    logic [INDEX_BITS-1:0] data_waddr;
    logic [LINE_SIZE-1:0]  data_wdata;
    logic                  valid_we;
    logic [INDEX_BITS-1:0] valid_waddr;

    // =========================================================================
    // Valid bits logic (flip-flops, can be reset)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_SETS; i++) begin
                valid_bits[i] <= 1'b0;
            end
        end else if (valid_we) begin
            valid_bits[valid_waddr] <= 1'b1;
        end
    end

    // =========================================================================
    // Main FSM
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state          <= IDLE;
            cpu_resp_valid <= 1'b0;
            cpu_resp_hit   <= 1'b0;
            mem_req_valid  <= 1'b0;
            tag_we         <= 1'b0;
            data_we        <= 1'b0;
            valid_we       <= 1'b0;
            addr_q         <= '0;
        end else begin
            // Default: clear write enables (pulse-style)
            tag_we   <= 1'b0;
            data_we  <= 1'b0;
            valid_we <= 1'b0;

            // BRAM synchronous read (1-cycle latency from address)
            tag_bram_out   <= tag_ram[addr_q[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS]];
            data_bram_out  <= data_ram[addr_q[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS]];
            valid_bram_out <= valid_bits[addr_q[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS]];

            // Output register (absorbed into BRAM output reg by synthesis tools)
            tag_read_q   <= tag_bram_out;
            data_read_q  <= data_bram_out;
            valid_read_q <= valid_bram_out;

            case (state)
                IDLE: begin
                    cpu_resp_valid <= 1'b0;
                    cpu_resp_hit   <= 1'b0;
                    mem_req_valid  <= 1'b0;
                    if (cpu_req_valid) begin
                        addr_q <= cpu_req_pc;
                        state  <= READ_RAM;
                    end
                end

                READ_RAM: begin
                    state <= READ_REG;
                end

                READ_REG: begin
                    state <= COMPARE;
                end

                COMPARE: begin
                    cpu_resp_valid <= 1'b0;
                    cpu_resp_hit   <= 1'b0;
                    if (is_hit) begin
                        cpu_resp_valid <= 1'b1;
                        cpu_resp_hit   <= 1'b1;
                        cpu_resp_data  <= data_read_q;
                        state          <= IDLE;
                    end else begin
                        mem_req_valid <= 1'b1;
                        mem_req_addr  <= {addr_tag, addr_index, {OFFSET_BITS{1'b0}}};
                        state         <= ALLOCATE;
                    end
                end

                ALLOCATE: begin
                    if (!mem_req_ready) begin
                        mem_req_valid <= 1'b1;
                        mem_req_addr  <= {addr_tag, addr_index, {OFFSET_BITS{1'b0}}};
                    end
                    
                    if (mem_resp_valid) begin
                        data_we    <= 1'b1;
                        data_waddr <= addr_index;
                        data_wdata <= mem_resp_data;
                        
                        tag_we     <= 1'b1;
                        tag_waddr  <= addr_index;
                        tag_wdata  <= addr_tag;
                        
                        valid_we   <= 1'b1;
                        valid_waddr <= addr_index;
                        
                        cpu_resp_valid <= 1'b1;
                        cpu_resp_hit   <= 1'b0;
                        cpu_resp_data  <= mem_resp_data;
                        mem_req_valid  <= 1'b0;
                        state          <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    // =========================================================================
    // BRAM write paths (separate always_ff, NO RESET)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (tag_we)
            tag_ram[tag_waddr] <= tag_wdata;
    end

    always_ff @(posedge clk) begin
        if (data_we)
            data_ram[data_waddr] <= data_wdata;
    end

    // =========================================================================
    // SIMULATION INITIALIZATION (V4.2 X-STATE FIX)
    // Fixes X-state propagation in XSim by initializing BRAMs to 0.
    // This does NOT affect synthesis (ignored by Vivado for BRAM inference).
    // =========================================================================
    integer ii;
    initial begin
        for (ii = 0; ii < NUM_SETS; ii = ii + 1) begin
            tag_ram[ii]  = '0;
            data_ram[ii] = '0;
        end
    end

    // =========================================================================
    // Outputs
    // =========================================================================
    assign cpu_req_ready = (state == IDLE);

endmodule