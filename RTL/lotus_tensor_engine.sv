`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:      Lotus Omni (Fabless AI Semiconductor)
// Engineer:     Sanuka Nethmira Amarasekara
//
// Module Name:  lotus_tensor_engine
// Revision:     3.0.0 (OUTER-PRODUCT FEED FIX)
//
// CHANGELOG:
//   v3.0.0 - DATAFLOW ALIGNMENT FIX (pairs with PE V10.0 + Array V5.0)
//              • array_enable now high during S_FEED + S_DRAIN
//                (pipeline needs extra cycles to flush after last feed)
//              • Activation feed changed from ROW-wise to COLUMN-wise
//                (transpose) to match outer-product accumulation:
//                PE(i,j) needs a_in[i]=A[i][k], b_in[j]=B[k][j]
//              • Feed outputs gated to ZERO during S_DRAIN
//                (accumulator holds result, pipeline flushes safely)
//              • NEW output: feed_first (asserted on first feed cycle,
//                used by top-level to clear PE accumulators)
//   v2.0.0 - Complete tape-out rewrite (preserved)
//   v1.0.0 - Initial implementation
//
// Limitations: (unchanged from v2.0.0)
//   • Single outstanding memory request (no request pipelining)
//   • Assumes in-order cache responses
//   • MATRIX_DIM must be a power of 2
//////////////////////////////////////////////////////////////////////////////////

module lotus_tensor_engine #(
    parameter int MATRIX_DIM      = 8,
    parameter int DRAIN_LATENCY   = 24,
    parameter int ADDR_WIDTH      = 64,
    parameter int LINE_WIDTH      = 512,
    parameter int PRF_DEST_WIDTH  = 7,
    parameter int CDB_DATA_WIDTH  = 64
) (
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        flush,

    // Issue Interface
    input  logic                        issue_valid,
    input  logic [PRF_DEST_WIDTH-1:0]   issue_p_dest,
    input  logic [ADDR_WIDTH-1:0]       issue_base_addr,
    input  logic [2:0]                  issue_funct3,
    input  logic [1:0]                  issue_precision,

    // Memory Streaming Interface
    output logic                        mem_req_valid,
    output logic [ADDR_WIDTH-1:0]       mem_req_addr,
    input  logic                        mem_req_ready,
    input  logic                        mem_resp_valid,
    input  logic [LINE_WIDTH-1:0]       mem_resp_data,

    // Systolic Array Interface
    output logic [127:0]                weight_bf16_out,
    output logic [127:0]                input_bf16_out,
    output logic [63:0]                 weight_int8_out,
    output logic [63:0]                 input_int8_out,
    output logic                        array_enable,
    output logic                        tensor_array_busy,
    output logic                        feed_first,       // V3.0 NEW

    input  logic [31:0]                 bf16_results [0:MATRIX_DIM-1][0:MATRIX_DIM-1],
    input  logic signed [31:0]          int8_results [0:MATRIX_DIM-1][0:MATRIX_DIM-1],

    // CDB Interface
    output logic                        tensor_cdb_valid,
    output logic [PRF_DEST_WIDTH-1:0]   tensor_cdb_p_dest,
    output logic [CDB_DATA_WIDTH-1:0]   tensor_cdb_data,
    input  logic                        tensor_cdb_ready,

    // Status
    output logic                        engine_ready
);

    //=============================================================================
    //  LOCALPARAMS
    //=============================================================================
    localparam int BF16_ELEM_BITS = 16;
    localparam int INT8_ELEM_BITS = 8;
    localparam int BF16_ROW_BITS  = MATRIX_DIM * BF16_ELEM_BITS;
    localparam int INT8_ROW_BITS  = MATRIX_DIM * INT8_ELEM_BITS;
    localparam int BF16_ROWS_PER_LINE = LINE_WIDTH / BF16_ROW_BITS;
    localparam int INT8_ROWS_PER_LINE = LINE_WIDTH / INT8_ROW_BITS;
    localparam int BF16_NUM_LINES = MATRIX_DIM / BF16_ROWS_PER_LINE;
    localparam int INT8_NUM_LINES = MATRIX_DIM / INT8_ROWS_PER_LINE;
    localparam int MAX_NUM_LINES = (BF16_NUM_LINES > INT8_NUM_LINES) ?
                                   BF16_NUM_LINES : INT8_NUM_LINES;
    localparam int LINE_CNT_BITS   = $clog2(MAX_NUM_LINES);
    localparam int ROW_IDX_BITS    = $clog2(MATRIX_DIM);
    localparam int DRAIN_CNT_BITS  = $clog2(DRAIN_LATENCY);
    localparam int WB_IDX_BITS     = $clog2(MATRIX_DIM * MATRIX_DIM);
    localparam int TOTAL_RESULTS   = MATRIX_DIM * MATRIX_DIM;
    localparam logic [WB_IDX_BITS-1:0] MAX_WB_IDX = TOTAL_RESULTS - 1;

    localparam logic [2:0] OP_WEIGHT_LOAD = 3'b000;
    localparam logic [2:0] OP_MATMUL      = 3'b001;
    localparam logic [1:0] PREC_BF16 = 2'b00;
    localparam logic [1:0] PREC_INT8 = 2'b01;
    localparam int LINE_BYTES = LINE_WIDTH / 8;

    //=============================================================================
    //  STATE ENCODING
    //=============================================================================
    typedef enum logic [2:0] {
        S_IDLE     = 3'b000,
        S_MEM_REQ  = 3'b001,
        S_MEM_WAIT = 3'b010,
        S_FEED     = 3'b011,
        S_DRAIN    = 3'b100,
        S_WB       = 3'b101,
        S_ILLEGAL  = 3'b111
    } state_t;

    //=============================================================================
    //  STATE REGISTERS
    //=============================================================================
    state_t                          state_r;
    logic [PRF_DEST_WIDTH-1:0]       dest_r;
    logic [1:0]                      prec_r;
    logic [2:0]                      op_r;
    logic                            is_weight_op_r;
    logic                            is_compute_op_r;
    logic                            is_bf16_r;
    logic [ADDR_WIDTH-1:0]           addr_r;
    logic [LINE_CNT_BITS-1:0]        line_cnt_r;
    logic [ROW_IDX_BITS-1:0]         feed_row_r;
    logic [DRAIN_CNT_BITS-1:0]       drain_cnt_r;
    logic [WB_IDX_BITS-1:0]          wb_idx_r;

    //=============================================================================
    //  DATA BUFFERS
    //=============================================================================
    logic [127:0] weight_buf [0:MATRIX_DIM-1];
    logic [127:0] act_buf    [0:MATRIX_DIM-1];

    //=============================================================================
    //  DERIVED COMBINATIONAL SIGNALS
    //=============================================================================
    logic                            last_line;
    logic                            lines_needed_is_1;
    logic [LINE_CNT_BITS-1:0]        max_line_cnt_m1;

    assign lines_needed_is_1 = is_bf16_r ? (BF16_NUM_LINES == 1) : (INT8_NUM_LINES == 1);
    assign max_line_cnt_m1   = MAX_NUM_LINES - 1;
    assign last_line = lines_needed_is_1 ?
                       (line_cnt_r == '0) :
                       (line_cnt_r == max_line_cnt_m1);

    logic                            all_rows_fed;
    logic [ROW_IDX_BITS-1:0]         max_row_idx;
    assign max_row_idx  = MATRIX_DIM - 1;
    assign all_rows_fed = (feed_row_r == max_row_idx);

    logic                            drain_done;
    logic [DRAIN_CNT_BITS-1:0]       max_drain_cnt;
    assign max_drain_cnt = DRAIN_LATENCY - 1;
    assign drain_done    = (drain_cnt_r == max_drain_cnt);

    logic                            all_wb_done;
    assign all_wb_done = (wb_idx_r == MAX_WB_IDX);

    logic [ROW_IDX_BITS-1:0]         wb_row;
    logic [ROW_IDX_BITS-1:0]         wb_col;
    assign wb_row = wb_idx_r[WB_IDX_BITS-1:ROW_IDX_BITS];
    assign wb_col = wb_idx_r[ROW_IDX_BITS-1:0];

    //=============================================================================
    //  OUTPUT ASSIGNMENTS
    //=============================================================================
    assign engine_ready      = (state_r == S_IDLE);
    assign tensor_array_busy = (state_r != S_IDLE);

    assign mem_req_valid = (state_r == S_MEM_REQ);
    assign mem_req_addr  = addr_r;

    // =========================================================================
    //  V3.0 FIX: array_enable HIGH during FEED + DRAIN
    //  The PE pipeline (array input reg + PE stages 1-3) needs 4 cycles total.
    //  The last real data enters at cycle 7 of S_FEED. It needs 3 more cycles
    //  to propagate through the PE pipeline. Keeping enable high during
    //  S_DRAIN provides those cycles while feeding zeros (which add 0 to the
    //  accumulator, preserving the result).
    // =========================================================================
    assign array_enable = (state_r == S_FEED) || (state_r == S_DRAIN);

    // =========================================================================
    //  V3.0 FIX: feed_first - asserted ONLY on the first feed cycle.
    //  Top-level ORs this with rob_flush_reg to clear PE accumulators.
    // =========================================================================
    assign feed_first = (state_r == S_FEED) && (feed_row_r == '0);

    // =========================================================================
    //  V3.0 FIX: Feed outputs gated to ZERO during S_DRAIN.
    //  During S_FEED: real data from buffers.
    //  During S_DRAIN: zeros (PE accumulates 0×0=0, result unchanged).
    // =========================================================================
    assign weight_bf16_out = (state_r == S_FEED) ? weight_buf[feed_row_r] : 128'h0;
    assign weight_int8_out = (state_r == S_FEED) ? weight_buf[feed_row_r][63:0] : 64'h0;

    // =========================================================================
    //  V3.0 FIX: Activation feed changed to COLUMN-WISE (transpose).
    //  OLD: input_bf16_out = act_buf[feed_row_r]  → a_in[g] = A[k][g] (ROW k)
    //  NEW: input_bf16_out[g] = act_buf[g][k]    → a_in[g] = A[g][k] (COL k)
    //
    //  For outer-product accumulation: PE(i,j) needs a_in[i]=A[i][k],
    //  b_in[j]=B[k][j]. Weight row feed gives b_in[j]=B[k][j] ✓.
    //  Activation column feed gives a_in[i]=A[i][k] ✓.
    // =========================================================================
    genvar gc;
    generate
        for (gc = 0; gc < MATRIX_DIM; gc++) begin : gen_col_feed_bf16
            assign input_bf16_out[gc*BF16_ELEM_BITS +: BF16_ELEM_BITS] =
                (state_r == S_FEED) ?
                    act_buf[gc][feed_row_r*BF16_ELEM_BITS +: BF16_ELEM_BITS] :
                    {BF16_ELEM_BITS{1'b0}};
        end
        for (gc = 0; gc < MATRIX_DIM; gc++) begin : gen_col_feed_int8
            assign input_int8_out[gc*INT8_ELEM_BITS +: INT8_ELEM_BITS] =
                (state_r == S_FEED) ?
                    act_buf[gc][feed_row_r*INT8_ELEM_BITS +: INT8_ELEM_BITS] :
                    {INT8_ELEM_BITS{1'b0}};
        end
    endgenerate

    //=============================================================================
    //  MAIN SEQUENTIAL LOGIC
    //=============================================================================
    always_ff @(posedge clk or negedge rst_n) begin : proc_engine_fsm
        if (!rst_n || flush) begin
            state_r          <= S_IDLE;
            dest_r           <= '0;
            prec_r           <= PREC_BF16;
            op_r             <= OP_WEIGHT_LOAD;
            is_weight_op_r   <= 1'b0;
            is_compute_op_r  <= 1'b0;
            is_bf16_r        <= 1'b1;
            addr_r           <= '0;
            line_cnt_r       <= '0;
            feed_row_r       <= '0;
            drain_cnt_r      <= '0;
            wb_idx_r         <= '0;
            tensor_cdb_valid <= 1'b0;
            tensor_cdb_p_dest <= '0;
            tensor_cdb_data  <= '0;
            for (int i = 0; i < MATRIX_DIM; i++) begin
                weight_buf[i] <= '0;
                act_buf[i]    <= '0;
            end
        end else begin
            tensor_cdb_valid <= 1'b0;

            case (state_r)

                S_IDLE: begin
                    if (issue_valid) begin
                        dest_r          <= issue_p_dest;
                        prec_r          <= issue_precision;
                        op_r            <= issue_funct3;
                        is_weight_op_r  <= (issue_funct3 == OP_WEIGHT_LOAD);
                        is_compute_op_r <= (issue_funct3 == OP_MATMUL);
                        is_bf16_r       <= (issue_precision == PREC_BF16);
                        addr_r          <= issue_base_addr;
                        line_cnt_r      <= '0;
                        feed_row_r      <= '0;
                        drain_cnt_r     <= '0;
                        wb_idx_r        <= '0;

                        if ((issue_funct3 == OP_WEIGHT_LOAD || issue_funct3 == OP_MATMUL) &&
                            (issue_precision == PREC_BF16 || issue_precision == PREC_INT8))
                            state_r <= S_MEM_REQ;
                    end
                end

                S_MEM_REQ: begin
                    if (mem_req_ready)
                        state_r <= S_MEM_WAIT;
                end

                S_MEM_WAIT: begin
                    if (mem_resp_valid) begin
                        if (is_weight_op_r) begin
                            if (is_bf16_r) begin
                                for (int i = 0; i < BF16_ROWS_PER_LINE; i++)
                                    weight_buf[line_cnt_r * BF16_ROWS_PER_LINE + i]
                                        <= mem_resp_data[i*BF16_ROW_BITS +: BF16_ROW_BITS];
                            end else begin
                                for (int i = 0; i < INT8_ROWS_PER_LINE; i++)
                                    weight_buf[line_cnt_r * INT8_ROWS_PER_LINE + i]
                                        <= {{64{1'b0}},
                                            mem_resp_data[i*INT8_ROW_BITS +: INT8_ROW_BITS]};
                            end
                        end else begin
                            if (is_bf16_r) begin
                                for (int i = 0; i < BF16_ROWS_PER_LINE; i++)
                                    act_buf[line_cnt_r * BF16_ROWS_PER_LINE + i]
                                        <= mem_resp_data[i*BF16_ROW_BITS +: BF16_ROW_BITS];
                            end else begin
                                for (int i = 0; i < INT8_ROWS_PER_LINE; i++)
                                    act_buf[line_cnt_r * INT8_ROWS_PER_LINE + i]
                                        <= {{64{1'b0}},
                                            mem_resp_data[i*INT8_ROW_BITS +: INT8_ROW_BITS]};
                            end
                        end

                        if (last_line) begin
                            if (is_compute_op_r) begin
                                state_r    <= S_FEED;
                                feed_row_r <= '0;
                            end else begin
                                state_r <= S_IDLE;
                            end
                        end else begin
                            addr_r     <= addr_r + ADDR_WIDTH'(LINE_BYTES);
                            line_cnt_r <= line_cnt_r + 1'b1;
                            state_r    <= S_MEM_REQ;
                        end
                    end
                end

                S_FEED: begin
                    if (all_rows_fed) begin
                        state_r     <= S_DRAIN;
                        drain_cnt_r <= '0;
                    end else begin
                        feed_row_r <= feed_row_r + 1'b1;
                    end
                end

                S_DRAIN: begin
                    if (drain_done) begin
                        state_r  <= S_WB;
                        wb_idx_r <= '0;
                    end else begin
                        drain_cnt_r <= drain_cnt_r + 1'b1;
                    end
                end

                S_WB: begin
                    if (tensor_cdb_ready) begin
                        tensor_cdb_valid  <= 1'b1;
                        tensor_cdb_p_dest <= dest_r + wb_idx_r;

                        if (is_bf16_r) begin
                            tensor_cdb_data <= {{
                                (CDB_DATA_WIDTH-32){bf16_results[wb_row][wb_col][31]}
                            }, bf16_results[wb_row][wb_col]};
                        end else begin
                            tensor_cdb_data <= {{
                                (CDB_DATA_WIDTH-32){int8_results[wb_row][wb_col][31]}
                            }, int8_results[wb_row][wb_col]};
                        end

                        if (all_wb_done)
                            state_r <= S_IDLE;
                        else
                            wb_idx_r <= wb_idx_r + 1'b1;
                    end
                end

                S_ILLEGAL: state_r <= S_IDLE;
                default:   state_r <= S_IDLE;

            endcase
        end
    end : proc_engine_fsm

endmodule : lotus_tensor_engine