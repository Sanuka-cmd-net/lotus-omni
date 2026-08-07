`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// lotus_l1d_cache - V8.0 FULL-LINE RESPONSE
//
// FIX L1D-004 (THIS VERSION): cpu_resp_data widened from 64-bit word to
//   512-bit FULL cache line. The tensor engine streams 512-bit lines, but the
//   old 64-bit word-select returned only one 64-bit word, corrupting tensor
//   data (every-other-element zeros). The scalar core top now selects its
//   64-bit word by address offset (see lotus_omni_core_top_v2 load path).
//
// FIX L1D-001: Removed if(!rst_n) from BRAM write always_ff - preserves BRAM inference
// FIX L1D-002: RETRY serves fill_data_q (new line) not stale evicted data
// FIX L1D-003: Removed automatic variable from always_comb - Vivado incompatible
//////////////////////////////////////////////////////////////////////////////////

module lotus_l1d_cache #(
    parameter ADDR_WIDTH = 64,
    parameter DATA_WIDTH = 64,
    parameter LINE_SIZE  = 512,
    parameter NUM_LINES  = 64
)(
    input  logic clk,
    input  logic rst_n,
    input  logic                  cpu_req_valid,
    input  logic                  cpu_req_rw,
    input  logic [ADDR_WIDTH-1:0] cpu_req_addr,
    input  logic [DATA_WIDTH-1:0] cpu_req_data,
    input  logic [7:0]            cpu_req_wmask,
    output logic                  cpu_req_ready,
    output logic                  cpu_resp_valid,
    output logic [LINE_SIZE-1:0]  cpu_resp_data,   // V8.0: 512-bit full line
    output logic                  cpu_resp_hit,
    output logic                  mem_req_valid,
    output logic                  mem_req_rw,
    output logic [ADDR_WIDTH-1:0] mem_req_addr,
    output logic [LINE_SIZE-1:0]  mem_req_data,
    input  logic                  mem_req_ready,
    input  logic                  mem_resp_valid,
    input  logic [LINE_SIZE-1:0]  mem_resp_data
);

    localparam OFFSET_BITS      = 6;
    localparam INDEX_BITS       = $clog2(NUM_LINES);
    localparam TAG_BITS         = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS;
    localparam ZERO_OFFSET      = {OFFSET_BITS{1'b0}};
    localparam DATA_WIDTH_LOCAL = LINE_SIZE;

    // =========================================================================
    // BRAM ARRAYS
    // =========================================================================
    (* ram_style = "block" *)
    logic [LINE_SIZE-1:0]  data_ram [NUM_LINES-1:0];
    (* ram_style = "block" *)
    logic [TAG_BITS+1:0]   tag_ram  [NUM_LINES-1:0];

    typedef struct packed {
        logic [TAG_BITS-1:0]    tag;
        logic [INDEX_BITS-1:0]  index;
        logic [OFFSET_BITS-1:0] offset;
    } cache_addr_t;

    typedef enum logic [2:0] {
        IDLE      = 3'b000,
        READ_RAM  = 3'b001,
        COMPARE   = 3'b010,
        WRITEBACK = 3'b011,
        ALLOCATE  = 3'b100,
        RETRY     = 3'b101
    } cache_state_t;

    // =========================================================================
    // STATE AND CONTROL REGISTERS
    // =========================================================================
    cache_state_t            state, next_state;
    logic                    req_rw_q;
    cache_addr_t             addr_q;
    logic [DATA_WIDTH-1:0]   data_q;
    logic [7:0]              wmask_q;

    // =========================================================================
    // BRAM OUTPUT REGISTERS
    // =========================================================================
    logic [DATA_WIDTH_LOCAL-1:0] data_read_out;
    logic [TAG_BITS+1:0]         tag_read_out;

    // =========================================================================
    // DERIVED TAG SIGNALS
    // =========================================================================
    logic                tag_valid;
    logic                tag_dirty;
    logic [TAG_BITS-1:0] tag_val;
    logic                is_hit;

    // =========================================================================
    // WRITE CONTROL SIGNALS
    // =========================================================================
    logic                        write_dirty_data;
    logic [DATA_WIDTH_LOCAL-1:0] merged_data;
    logic                        data_ram_we;
    logic                        tag_ram_we;
    logic [DATA_WIDTH_LOCAL-1:0] data_to_write;
    logic [TAG_BITS+1:0]         tag_to_write;
    logic [INDEX_BITS-1:0]       write_index;

    logic [DATA_WIDTH_LOCAL-1:0] writeback_data;
    logic [TAG_BITS-1:0]         writeback_tag;

    logic [DATA_WIDTH_LOCAL-1:0] fill_data_q;

    // V8.0: module-scope response line (Vivado-compatible, no automatic var)
    logic [DATA_WIDTH_LOCAL-1:0] resp_line;

    // =========================================================================
    // BRAM READ INDEX
    // =========================================================================
    logic [INDEX_BITS-1:0] read_index;
    logic                  do_read;

    always_comb begin
        do_read    = cpu_req_valid && (state == IDLE);
        read_index = do_read
                     ? cpu_req_addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS]
                     : addr_q.index;
    end

    // =========================================================================
    // BRAM READ - clocked output
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            data_read_out <= {DATA_WIDTH_LOCAL{1'b0}};
            tag_read_out  <= {(TAG_BITS+2){1'b0}};
        end else begin
            data_read_out <= data_ram[read_index];
            tag_read_out  <= tag_ram[read_index];
        end
    end

    // =========================================================================
    // TAG DECODE
    // =========================================================================
    always_comb begin
        tag_valid = tag_read_out[TAG_BITS+1];
        tag_dirty = tag_read_out[TAG_BITS];
        tag_val   = tag_read_out[TAG_BITS-1:0];
        is_hit    = (state == COMPARE) && tag_valid && (tag_val == addr_q.tag);
    end

    // =========================================================================
    // FSM STATE REGISTER
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state            <= IDLE;
            req_rw_q         <= 1'b0;
            addr_q           <= '0;
            data_q           <= {DATA_WIDTH{1'b0}};
            wmask_q          <= 8'b0;
            writeback_data   <= {DATA_WIDTH_LOCAL{1'b0}};
            writeback_tag    <= {TAG_BITS{1'b0}};
            write_dirty_data <= 1'b0;
            fill_data_q      <= {DATA_WIDTH_LOCAL{1'b0}};
        end else begin
            case (state)
                IDLE: begin
                    if (cpu_req_valid) begin
                        req_rw_q         <= cpu_req_rw;
                        addr_q           <= cpu_req_addr;
                        data_q           <= cpu_req_data;
                        wmask_q          <= cpu_req_wmask;
                        write_dirty_data <= 1'b0;
                    end
                end

                COMPARE: begin
                    if (!is_hit && tag_valid && tag_dirty) begin
                        writeback_data   <= data_read_out;
                        writeback_tag    <= tag_val[TAG_BITS-1:0];
                        write_dirty_data <= 1'b1;
                    end else begin
                        write_dirty_data <= 1'b0;
                    end
                end

                ALLOCATE: begin
                    if (mem_resp_valid)
                        fill_data_q <= mem_resp_data;
                end

                default: write_dirty_data <= 1'b0;
            endcase

            state <= next_state;
        end
    end

    // =========================================================================
    // FIX L1D-001: BRAM write always_ff - NO if(!rst_n) branch.
    // =========================================================================
    always_ff @(posedge clk) begin
        data_ram_we   <= 1'b0;
        tag_ram_we    <= 1'b0;
        data_to_write <= {DATA_WIDTH_LOCAL{1'b0}};
        tag_to_write  <= {(TAG_BITS+2){1'b0}};
        write_index   <= {INDEX_BITS{1'b0}};

        case (state)
            COMPARE: begin
                if (is_hit && req_rw_q) begin
                    data_ram_we   <= 1'b1;
                    tag_ram_we    <= 1'b1;
                    write_index   <= addr_q.index;
                    data_to_write <= merged_data;
                    tag_to_write  <= {1'b1, 1'b1, addr_q.tag};
                end
            end

            ALLOCATE: begin
                if (mem_resp_valid) begin
                    data_ram_we   <= 1'b1;
                    tag_ram_we    <= 1'b1;
                    write_index   <= addr_q.index;
                    data_to_write <= mem_resp_data;
                    tag_to_write  <= {1'b1, 1'b0, addr_q.tag};
                end
            end

            RETRY: begin
                if (req_rw_q) begin
                    data_ram_we   <= 1'b1;
                    tag_ram_we    <= 1'b1;
                    write_index   <= addr_q.index;
                    data_to_write <= merged_data;
                    tag_to_write  <= {1'b1, 1'b1, addr_q.tag};
                end
            end

            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (data_ram_we) data_ram[write_index] <= data_to_write;
    end

    always_ff @(posedge clk) begin
        if (tag_ram_we) tag_ram[write_index] <= tag_to_write;
    end

    // =========================================================================
    // MERGED DATA - for write-hit and write-after-fill
    // =========================================================================
    always_comb begin
        merged_data = (state == RETRY) ? fill_data_q : data_read_out;

        if ((state == COMPARE && is_hit && req_rw_q) ||
            (state == RETRY  && req_rw_q)) begin
            case (addr_q.offset[5:3])
                3'b000: for (int i=0;i<8;i++) if (wmask_q[i]) merged_data[0   +(i*8)+:8] = data_q[(i*8)+:8];
                3'b001: for (int i=0;i<8;i++) if (wmask_q[i]) merged_data[64  +(i*8)+:8] = data_q[(i*8)+:8];
                3'b010: for (int i=0;i<8;i++) if (wmask_q[i]) merged_data[128 +(i*8)+:8] = data_q[(i*8)+:8];
                3'b011: for (int i=0;i<8;i++) if (wmask_q[i]) merged_data[192 +(i*8)+:8] = data_q[(i*8)+:8];
                3'b100: for (int i=0;i<8;i++) if (wmask_q[i]) merged_data[256 +(i*8)+:8] = data_q[(i*8)+:8];
                3'b101: for (int i=0;i<8;i++) if (wmask_q[i]) merged_data[320 +(i*8)+:8] = data_q[(i*8)+:8];
                3'b110: for (int i=0;i<8;i++) if (wmask_q[i]) merged_data[384 +(i*8)+:8] = data_q[(i*8)+:8];
                3'b111: for (int i=0;i<8;i++) if (wmask_q[i]) merged_data[448 +(i*8)+:8] = data_q[(i*8)+:8];
                default: ;
            endcase
        end
    end

    // =========================================================================
    // FSM NEXT STATE
    // =========================================================================
    always_comb begin
        next_state = state;
        case (state)
            IDLE:      if (cpu_req_valid)         next_state = READ_RAM;
            READ_RAM:                              next_state = COMPARE;
            COMPARE: begin
                if (is_hit)                        next_state = IDLE;
                else if (tag_valid && tag_dirty)   next_state = WRITEBACK;
                else                               next_state = ALLOCATE;
            end
            WRITEBACK: if (mem_req_ready)          next_state = ALLOCATE;
            ALLOCATE:  if (mem_resp_valid)          next_state = RETRY;
            RETRY:                                  next_state = IDLE;
            default:                                next_state = IDLE;
        endcase
    end

    // =========================================================================
    // OUTPUT COMBINATIONAL LOGIC
    // V8.0: cpu_resp_data returns the FULL 512-bit line. The scalar core top
    //       selects its 64-bit word by address offset; the tensor engine uses
    //       the whole line.
    // =========================================================================
    always_comb begin
        cpu_req_ready  = (state == IDLE);
        cpu_resp_valid = (state == COMPARE && is_hit) || (state == RETRY);
        cpu_resp_hit   = cpu_resp_valid;

        resp_line     = (state == RETRY) ? fill_data_q : data_read_out;
        cpu_resp_data = resp_line;   // V8.0: full 512-bit line

        mem_req_valid = (state == WRITEBACK) || (state == ALLOCATE);
        mem_req_rw    = (state == WRITEBACK);
        mem_req_addr  = (state == WRITEBACK)
                        ? {writeback_tag, addr_q.index, ZERO_OFFSET}
                        : {addr_q.tag,    addr_q.index, ZERO_OFFSET};
        mem_req_data  = (state == WRITEBACK) ? writeback_data : data_read_out;
    end

    // =========================================================================
    // SIMULATION INITIALISATION
    // =========================================================================
    integer ii;
    initial begin
        for (ii = 0; ii < NUM_LINES; ii = ii + 1) begin
            data_ram[ii] = {DATA_WIDTH_LOCAL{1'b0}};
            tag_ram[ii]  = {(TAG_BITS+2){1'b0}};
        end
    end

endmodule