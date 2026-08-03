`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////////////////////
// Company:        Lotus Omni (Fabless AI Semiconductor)
// Engineer:       Sanuka Nethmira Amarasekara
// Module Name:    lotus_l2_cache - V7.6 RDW HAZARD BYPASS FIX
//
// FIX V7.6 (THIS VERSION):
//   1. RDW-2 (READ-DURING-WRITE HAZARD): V7.5 read directly from data_array 
//      in RESPOND state immediately after FILL_WAIT/FILL_SECOND wrote to it.
//      This causes a Read-During-Write timing mismatch if Vivado maps to BRAM.
//      Fix: Added `fill_resp_data` bypass register. DRAM response data is 
//      latched into it during FILL_WAIT. In RESPOND, if it was a Miss, data 
//      is read from `fill_resp_data` instead of the RAM array, completely 
//      eliminating the RDW hazard.
//////////////////////////////////////////////////////////////////////////////////

module lotus_l2_cache #(

    parameter ADDR_WIDTH = 64,
    parameter NUM_SETS   = 16,
    parameter NUM_WAYS   = 4,
    parameter LINE_SIZE  = 512

)(

    input  logic clk,
    input  logic rst_n,

    // L1D Interface
    input  logic                  l1d_req_valid,
    input  logic                  l1d_req_rw,
    input  logic [ADDR_WIDTH-1:0] l1d_req_addr,
    input  logic [LINE_SIZE-1:0]  l1d_req_data,
    output logic                  l1d_req_ready,
    output logic                  l1d_resp_valid,
    output logic [LINE_SIZE-1:0]  l1d_resp_data,

    // L1I Interface
    input  logic                  l1i_req_valid,
    input  logic [ADDR_WIDTH-1:0] l1i_req_addr,
    output logic                  l1i_req_ready,
    output logic                  l1i_resp_valid,
    output logic [LINE_SIZE-1:0]  l1i_resp_data,

    // DRAM Interface
    output logic                  dram_req_valid,
    output logic                  dram_req_rw,
    output logic [ADDR_WIDTH-1:0] dram_req_addr,
    output logic [1023:0]         dram_req_data,
    input  logic                  dram_req_ready,
    input  logic                  dram_resp_valid,
    input  logic [1023:0]         dram_resp_data

);

    localparam OFFSET_BITS      = 6;
    localparam INDEX_BITS       = $clog2(NUM_SETS);
    localparam TAG_BITS         = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS;
    localparam MAX_OUTSTANDING  = 4;
    localparam REQ_ID_BITS      = $clog2(MAX_OUTSTANDING);
    localparam WAYS_LOG2        = $clog2(NUM_WAYS);

    // =========================================================================
    // REQUEST QUEUE - 1D Flip-Flops
    // =========================================================================
    typedef struct packed {
        logic                  valid;
        logic                  is_l1i;
        logic                  req_rw;
        logic [ADDR_WIDTH-1:0] req_addr;
        logic [LINE_SIZE-1:0]  req_wdata;
    } req_queue_t;

    req_queue_t req_queue [0:MAX_OUTSTANDING-1];

    logic [REQ_ID_BITS-1:0] req_head;
    logic [REQ_ID_BITS-1:0] req_tail;
    logic [REQ_ID_BITS:0]   req_queue_count;
    logic req_queue_full;
    logic req_queue_empty;

    always_comb begin
        if (req_tail >= req_head)
            req_queue_count = req_tail - req_head;
        else
            req_queue_count = MAX_OUTSTANDING + req_tail - req_head;
        req_queue_full  = (req_queue_count >= (MAX_OUTSTANDING - 1));
        req_queue_empty = (req_queue_count == 0);
    end

    assign l1d_req_ready = !req_queue_full;
    assign l1i_req_ready = !req_queue_full && !l1d_req_valid;

    // =========================================================================
    // CACHE TAGS - SPLIT INTO 4 SEPARATE LUTRAM ARRAYS
    // =========================================================================
    (* ram_style = "distributed" *) logic tag_valid_w0 [0:NUM_SETS-1];
    (* ram_style = "distributed" *) logic tag_valid_w1 [0:NUM_SETS-1];
    (* ram_style = "distributed" *) logic tag_valid_w2 [0:NUM_SETS-1];
    (* ram_style = "distributed" *) logic tag_valid_w3 [0:NUM_SETS-1];

    (* ram_style = "distributed" *) logic tag_dirty_w0 [0:NUM_SETS-1];
    (* ram_style = "distributed" *) logic tag_dirty_w1 [0:NUM_SETS-1];
    (* ram_style = "distributed" *) logic tag_dirty_w2 [0:NUM_SETS-1];
    (* ram_style = "distributed" *) logic tag_dirty_w3 [0:NUM_SETS-1];

    (* ram_style = "distributed" *) logic [TAG_BITS-1:0] tag_data_w0 [0:NUM_SETS-1];
    (* ram_style = "distributed" *) logic [TAG_BITS-1:0] tag_data_w1 [0:NUM_SETS-1];
    (* ram_style = "distributed" *) logic [TAG_BITS-1:0] tag_data_w2 [0:NUM_SETS-1];
    (* ram_style = "distributed" *) logic [TAG_BITS-1:0] tag_data_w3 [0:NUM_SETS-1];

    // =========================================================================
    // CACHE DATA - SPLIT INTO 4 SEPARATE LUTRAM ARRAYS
    // =========================================================================
    (* ram_style = "distributed" *) logic [LINE_SIZE-1:0] data_array_w0 [0:NUM_SETS-1];
    (* ram_style = "distributed" *) logic [LINE_SIZE-1:0] data_array_w1 [0:NUM_SETS-1];
    (* ram_style = "distributed" *) logic [LINE_SIZE-1:0] data_array_w2 [0:NUM_SETS-1];
    (* ram_style = "distributed" *) logic [LINE_SIZE-1:0] data_array_w3 [0:NUM_SETS-1];

    // =========================================================================
    // Initialization for Simulation/FPGA Power-up
    // =========================================================================
    initial begin
        for (int i = 0; i < NUM_SETS; i++) begin
            tag_valid_w0[i] = 1'b0; tag_dirty_w0[i] = 1'b0; tag_data_w0[i] = '0;
            tag_valid_w1[i] = 1'b0; tag_dirty_w1[i] = 1'b0; tag_data_w1[i] = '0;
            tag_valid_w2[i] = 1'b0; tag_dirty_w2[i] = 1'b0; tag_data_w2[i] = '0;
            tag_valid_w3[i] = 1'b0; tag_dirty_w3[i] = 1'b0; tag_data_w3[i] = '0;
            data_array_w0[i] = '0; data_array_w1[i] = '0;
            data_array_w2[i] = '0; data_array_w3[i] = '0;
        end
    end

    // PLRU TREE - Registers
    logic [2:0] plru_tree [0:NUM_SETS-1];

    // =========================================================================
    // FSM STATES & REGISTERS
    // =========================================================================
    typedef enum logic [3:0] {
        IDLE           = 4'b0001,
        READ_TAGS      = 4'b0010,
        COMPARE_HIT    = 4'b0011,
        WRITEBACK      = 4'b0100,
        WRITEBACK_WAIT = 4'b0101,
        FILL           = 4'b0110,
        FILL_WAIT      = 4'b0111,
        FILL_SECOND    = 4'b1001,
        RESPOND        = 4'b1000
    } state_t;

    state_t                state;
    logic                  req_is_l1i;
    logic                  req_rw;
    logic [ADDR_WIDTH-1:0] req_addr;
    logic [LINE_SIZE-1:0]  req_wdata;
    logic [TAG_BITS-1:0]   req_tag;
    logic [INDEX_BITS-1:0] req_index;
    logic [1:0]            req_way;
    logic [TAG_BITS-1:0]   read_tag_0, read_tag_1, read_tag_2, read_tag_3;
    logic                  read_valid_0, read_valid_1, read_valid_2, read_valid_3;
    logic [INDEX_BITS-1:0] read_index;
    logic [1:0]            hit_way;
    logic                  is_hit;
    logic [1:0]            evict_way;
    logic                  bram_we;
    logic [INDEX_BITS-1:0] bram_windex;
    logic [1:0]            bram_wway;
    logic [LINE_SIZE-1:0]  bram_wdata;
    
    // FIX V7.6: Bypass Register to avoid Read-During-Write hazard
    logic [LINE_SIZE-1:0]  fill_resp_data;
    
    logic [ADDR_WIDTH-1:0] pending_addr;
    logic [LINE_SIZE-1:0]  pending_data;

    // =========================================================================
    // COMBINATIONAL LOGIC - Hit detection
    // =========================================================================
    always_comb begin
        is_hit  = 1'b0;
        hit_way = 2'h0;

        if (read_valid_0 && (read_tag_0 == req_tag)) begin
            is_hit  = 1'b1; hit_way = 2'h0;
        end else if (read_valid_1 && (read_tag_1 == req_tag)) begin
            is_hit  = 1'b1; hit_way = 2'h1;
        end else if (read_valid_2 && (read_tag_2 == req_tag)) begin
            is_hit  = 1'b1; hit_way = 2'h2;
        end else if (read_valid_3 && (read_tag_3 == req_tag)) begin
            is_hit  = 1'b1; hit_way = 2'h3;
        end

        if (plru_tree[req_index][0])
            evict_way = plru_tree[req_index][2] ? 2'h3 : 2'h2;
        else
            evict_way = plru_tree[req_index][1] ? 2'h1 : 2'h0;
    end

    // =========================================================================
    // TAG ARRAY READ
    // =========================================================================
    always_ff @(posedge clk) begin
        read_valid_0 <= tag_valid_w0[read_index];
        read_tag_0   <= tag_data_w0[read_index];
        read_valid_1 <= tag_valid_w1[read_index];
        read_tag_1   <= tag_data_w1[read_index];
        read_valid_2 <= tag_valid_w2[read_index];
        read_tag_2   <= tag_data_w2[read_index];
        read_valid_3 <= tag_valid_w3[read_index];
        read_tag_3   <= tag_data_w3[read_index];
    end

    // =========================================================================
    // REQUEST QUEUE ENQUEUE & DEQUEUE
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            req_tail <= '0;
            req_head <= '0;
            for (int i = 0; i < MAX_OUTSTANDING; i++) begin
                req_queue[i].valid <= 1'b0;
            end
        end else begin
            if (l1d_req_valid && !req_queue_full) begin
                req_queue[req_tail].valid     <= 1'b1;
                req_queue[req_tail].is_l1i    <= 1'b0;
                req_queue[req_tail].req_rw    <= l1d_req_rw;
                req_queue[req_tail].req_addr  <= l1d_req_addr;
                req_queue[req_tail].req_wdata <= l1d_req_data;
                req_tail <= (req_tail + 1) % MAX_OUTSTANDING;
            end
            else if (l1i_req_valid && !req_queue_full) begin
                req_queue[req_tail].valid     <= 1'b1;
                req_queue[req_tail].is_l1i    <= 1'b1;
                req_queue[req_tail].req_rw    <= 1'b0;
                req_queue[req_tail].req_addr  <= l1i_req_addr;
                req_queue[req_tail].req_wdata <= {LINE_SIZE{1'b0}};
                req_tail <= (req_tail + 1) % MAX_OUTSTANDING;
            end

            if (state == IDLE && !req_queue_empty) begin
                req_queue[req_head].valid <= 1'b0;
                req_head <= (req_head + 1) % MAX_OUTSTANDING;
            end
        end
    end

    // =========================================================================
    // MAIN FSM
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state                <= IDLE;
            l1d_resp_valid       <= 1'b0;
            l1i_resp_valid       <= 1'b0;
            dram_req_valid       <= 1'b0;
            bram_we              <= 1'b0;
            bram_windex          <= '0;
            bram_wway            <= 2'h0;
            bram_wdata           <= '0;
            fill_resp_data       <= '0;
            pending_addr         <= '0;
            pending_data         <= '0;
            read_index           <= '0;
            req_tag              <= '0;
            req_index            <= '0;
            req_way              <= 2'h0;
            req_is_l1i           <= 1'b0;
            req_rw               <= 1'b0;
            req_addr             <= '0;
            req_wdata            <= '0;
        end else begin
            l1d_resp_valid      <= 1'b0;
            l1i_resp_valid      <= 1'b0;
            dram_req_valid      <= 1'b0;
            bram_we             <= 1'b0;

            case (state)
                IDLE: begin
                    if (!req_queue_empty) begin
                        req_is_l1i      <= req_queue[req_head].is_l1i;
                        req_rw          <= req_queue[req_head].req_rw;
                        req_addr        <= req_queue[req_head].req_addr;
                        req_wdata       <= req_queue[req_head].req_wdata;
                        req_tag         <= req_queue[req_head].req_addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];
                        req_index       <= req_queue[req_head].req_addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];

                        read_index      <= req_queue[req_head].req_addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
                        state           <= READ_TAGS;
                    end
                end

                READ_TAGS: state <= COMPARE_HIT;

                COMPARE_HIT: begin
                    if (is_hit) begin
                        if (req_rw) begin
                            bram_we        <= 1'b1;
                            bram_windex    <= req_index;
                            bram_wway      <= hit_way;
                            bram_wdata     <= req_wdata;
                            l1d_resp_valid <= 1'b1;
                            l1d_resp_data  <= req_wdata;
                            state <= IDLE;
                        end else begin
                            state <= RESPOND;
                        end
                    end else begin
                        if (tag_dirty_w0[req_index] && evict_way == 2'h0 ||
                            tag_dirty_w1[req_index] && evict_way == 2'h1 ||
                            tag_dirty_w2[req_index] && evict_way == 2'h2 ||
                            tag_dirty_w3[req_index] && evict_way == 2'h3) begin
                            dram_req_valid <= 1'b1;
                            dram_req_rw    <= 1'b1;
                            case (evict_way)
                                2'h0: dram_req_addr <= {tag_data_w0[req_index], req_index, {OFFSET_BITS{1'b0}}};
                                2'h1: dram_req_addr <= {tag_data_w1[req_index], req_index, {OFFSET_BITS{1'b0}}};
                                2'h2: dram_req_addr <= {tag_data_w2[req_index], req_index, {OFFSET_BITS{1'b0}}};
                                2'h3: dram_req_addr <= {tag_data_w3[req_index], req_index, {OFFSET_BITS{1'b0}}};
                            endcase
                            case (evict_way)
                                2'h0: dram_req_data <= {data_array_w0[req_index], data_array_w0[req_index]};
                                2'h1: dram_req_data <= {data_array_w1[req_index], data_array_w1[req_index]};
                                2'h2: dram_req_data <= {data_array_w2[req_index], data_array_w2[req_index]};
                                2'h3: dram_req_data <= {data_array_w3[req_index], data_array_w3[req_index]};
                            endcase
                            state <= WRITEBACK;
                        end else begin
                            dram_req_valid <= 1'b1;
                            dram_req_rw    <= 1'b0;
                            dram_req_addr  <= {req_tag, req_index, {OFFSET_BITS{1'b0}}};
                            state <= FILL;
                        end
                    end
                end

                WRITEBACK: begin
                    dram_req_valid <= 1'b1;
                    dram_req_rw    <= 1'b1;
                    case (evict_way)
                        2'h0: dram_req_data <= {data_array_w0[req_index], data_array_w0[req_index]};
                        2'h1: dram_req_data <= {data_array_w1[req_index], data_array_w1[req_index]};
                        2'h2: dram_req_data <= {data_array_w2[req_index], data_array_w2[req_index]};
                        2'h3: dram_req_data <= {data_array_w3[req_index], data_array_w3[req_index]};
                    endcase

                    if (dram_req_ready) begin
                        state <= WRITEBACK_WAIT;
                    end
                end

                WRITEBACK_WAIT: begin
                    if (dram_resp_valid) begin
                        dram_req_rw     <= 1'b0;
                        dram_req_addr   <= {req_tag, req_index, {OFFSET_BITS{1'b0}}};
                        state <= FILL;
                    end
                end

                FILL: begin
                    dram_req_valid <= 1'b1;
                    dram_req_rw    <= 1'b0;
                    dram_req_addr  <= {req_tag, req_index, {OFFSET_BITS{1'b0}}};

                    if (dram_req_ready) begin
                        state <= FILL_WAIT;
                    end
                end

                FILL_WAIT: begin
                    if (dram_resp_valid) begin
                        bram_we        <= 1'b1;
                        bram_windex    <= req_index;
                        bram_wway      <= evict_way;
                        bram_wdata     <= dram_resp_data[511:0];
                        
                        // FIX V7.6: Latch data to bypass register to avoid RDW hazard
                        fill_resp_data <= dram_resp_data[511:0];

                        if (dram_resp_data[1023:512] != {LINE_SIZE{1'b0}}) begin
                            pending_addr <= req_addr + (1 << OFFSET_BITS);
                            pending_data <= dram_resp_data[1023:512];
                            state        <= FILL_SECOND;
                        end else begin
                            state        <= RESPOND;
                        end
                    end
                end

                FILL_SECOND: begin
                    bram_we     <= 1'b1;
                    bram_windex <= pending_addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
                    bram_wway   <= evict_way;
                    bram_wdata  <= pending_data;
                    state       <= RESPOND;
                end

                // FIX V7.6: Use bypass register `fill_resp_data` for Misses
                RESPOND: begin
                    if (req_is_l1i) begin
                        l1i_resp_valid <= 1'b1;
                        if (!is_hit) begin
                            l1i_resp_data <= fill_resp_data; // Bypass RAM
                        end else begin
                            case (hit_way)
                                2'h0: l1i_resp_data <= data_array_w0[req_index];
                                2'h1: l1i_resp_data <= data_array_w1[req_index];
                                2'h2: l1i_resp_data <= data_array_w2[req_index];
                                2'h3: l1i_resp_data <= data_array_w3[req_index];
                            endcase
                        end
                    end else if (!req_rw) begin
                        l1d_resp_valid <= 1'b1;
                        if (!is_hit) begin
                            l1d_resp_data <= fill_resp_data; // Bypass RAM
                        end else begin
                            case (hit_way)
                                2'h0: l1d_resp_data <= data_array_w0[req_index];
                                2'h1: l1d_resp_data <= data_array_w1[req_index];
                                2'h2: l1d_resp_data <= data_array_w2[req_index];
                                2'h3: l1d_resp_data <= data_array_w3[req_index];
                            endcase
                        end
                    end
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    // =========================================================================
    // LUTRAM WRITE (data arrays)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (bram_we) begin
            case (bram_wway)
                2'h0: data_array_w0[bram_windex] <= bram_wdata;
                2'h1: data_array_w1[bram_windex] <= bram_wdata;
                2'h2: data_array_w2[bram_windex] <= bram_wdata;
                2'h3: data_array_w3[bram_windex] <= bram_wdata;
            endcase
        end
    end

    // =========================================================================
    // TAG AND PLRU UPDATE
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int s = 0; s < NUM_SETS; s++) begin
                plru_tree[s] <= 3'h0;
            end
        end else begin
            if (state == FILL_WAIT && dram_resp_valid) begin
                case (evict_way)
                    2'h0: begin tag_valid_w0[req_index] <= 1'b1; tag_dirty_w0[req_index] <= req_rw; tag_data_w0[req_index] <= req_tag; end
                    2'h1: begin tag_valid_w1[req_index] <= 1'b1; tag_dirty_w1[req_index] <= req_rw; tag_data_w1[req_index] <= req_tag; end
                    2'h2: begin tag_valid_w2[req_index] <= 1'b1; tag_dirty_w2[req_index] <= req_rw; tag_data_w2[req_index] <= req_tag; end
                    2'h3: begin tag_valid_w3[req_index] <= 1'b1; tag_dirty_w3[req_index] <= req_rw; tag_data_w3[req_index] <= req_tag; end
                endcase
            end else if (state == FILL_SECOND) begin
                automatic logic [INDEX_BITS-1:0] p_idx = pending_addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
                automatic logic [TAG_BITS-1:0]   p_tag = pending_addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];
                case (evict_way)
                    2'h0: begin tag_valid_w0[p_idx] <= 1'b1; tag_dirty_w0[p_idx] <= 1'b0; tag_data_w0[p_idx] <= p_tag; end
                    2'h1: begin tag_valid_w1[p_idx] <= 1'b1; tag_dirty_w1[p_idx] <= 1'b0; tag_data_w1[p_idx] <= p_tag; end
                    2'h2: begin tag_valid_w2[p_idx] <= 1'b1; tag_dirty_w2[p_idx] <= 1'b0; tag_data_w2[p_idx] <= p_tag; end
                    2'h3: begin tag_valid_w3[p_idx] <= 1'b1; tag_dirty_w3[p_idx] <= 1'b0; tag_data_w3[p_idx] <= p_tag; end
                endcase
            end else if (state == COMPARE_HIT && is_hit && req_rw) begin
                case (hit_way)
                    2'h0: tag_dirty_w0[req_index] <= 1'b1;
                    2'h1: tag_dirty_w1[req_index] <= 1'b1;
                    2'h2: tag_dirty_w2[req_index] <= 1'b1;
                    2'h3: tag_dirty_w3[req_index] <= 1'b1;
                endcase
            end else if (state == WRITEBACK_WAIT && dram_resp_valid) begin
                case (evict_way)
                    2'h0: tag_dirty_w0[req_index] <= 1'b0;
                    2'h1: tag_dirty_w1[req_index] <= 1'b0;
                    2'h2: tag_dirty_w2[req_index] <= 1'b0;
                    2'h3: tag_dirty_w3[req_index] <= 1'b0;
                endcase
            end

            if (state == RESPOND) begin
                case (is_hit ? hit_way : evict_way)
                    2'h0: plru_tree[req_index] <= {plru_tree[req_index][2], 1'b0, 1'b0};
                    2'h1: plru_tree[req_index] <= {plru_tree[req_index][2], 1'b1, 1'b0};
                    2'h2: plru_tree[req_index] <= {1'b0, plru_tree[req_index][1], 1'b1};
                    2'h3: plru_tree[req_index] <= {1'b1, plru_tree[req_index][1], 1'b1};
                endcase
            end
        end
    end

endmodule