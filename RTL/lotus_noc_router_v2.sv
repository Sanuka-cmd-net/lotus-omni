`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// lotus_noc_router_masterpiece - V3.2 P0 SET/RESET PRIORITY FIX
//
// FIX NOC-P0-001: Set/Reset priority (Synth 8-7137) fixed for:
//   - local_payload_reg, local_flit_type_reg
//   - tx_payload_reg[4:1], tx_flit_type_reg[4:1]
//   All conditional set logic now nested inside else{} block so reset
//   has unambiguous highest priority.
//
// Preserved fixes from V3.1:
//   - RAM Inference: Isolated FIFO arrays into noc_fifo_storage sub-module
//   - Set/Reset Priority: active_dest_x/y with proper priority chain
//   - All working formulas and values PRESERVED
//////////////////////////////////////////////////////////////////////////////////

module lotus_noc_router_masterpiece #(
    parameter DATA_WIDTH = 64,
    parameter CORD_WIDTH = 4,
    parameter FIFO_DEPTH = 4
)(
    input  logic clk, rst_n,

    input  logic [CORD_WIDTH-1:0] my_x,
    input  logic [CORD_WIDTH-1:0] my_y,

    // --- 5 INPUT PORTS (0:Local, 1:North, 2:South, 3:East, 4:West) ---
    input  logic [4:0]                  rx_valid,
    input  logic [4:0][1:0]             rx_flit_type,
    input  logic [4:0][CORD_WIDTH-1:0]  rx_dest_x,
    input  logic [4:0][CORD_WIDTH-1:0]  rx_dest_y,
    input  logic [4:0][DATA_WIDTH-1:0]  rx_payload,
    output logic [4:0]                  rx_ready,

    // --- 4 NETWORK OUTPUT PORTS (1:North, 2:South, 3:East, 4:West) ---
    output logic [4:1]                  tx_valid,
    output logic [4:1][1:0]             tx_flit_type,
    output logic [4:1][DATA_WIDTH-1:0]  tx_payload,
    input  logic [4:1]                  tx_ready,

    // --- 1 LOCAL OUTPUT PORT ---
    output logic                        local_valid,
    output logic [1:0]                  local_flit_type,
    output logic [DATA_WIDTH-1:0]       local_payload,
    input  logic                        local_ready
);

    localparam LOCAL = 0, NORTH = 1, SOUTH = 2, EAST = 3, WEST = 4;
    localparam N_PORTS = 5;
    localparam WR_PTR_WIDTH = $clog2(FIFO_DEPTH);

    logic [WR_PTR_WIDTH-1:0]  wr_ptr [0:N_PORTS-1];
    logic [WR_PTR_WIDTH-1:0]  rd_ptr [0:N_PORTS-1];
    logic [2:0]               count  [0:N_PORTS-1];
    logic [N_PORTS-1:0]       push, pop;

    assign rx_ready[0] = count[0] < FIFO_DEPTH;
    assign rx_ready[1] = count[1] < FIFO_DEPTH;
    assign rx_ready[2] = count[2] < FIFO_DEPTH;
    assign rx_ready[3] = count[3] < FIFO_DEPTH;
    assign rx_ready[4] = count[4] < FIFO_DEPTH;

    assign push[0] = rx_valid[0] && rx_ready[0];
    assign push[1] = rx_valid[1] && rx_ready[1];
    assign push[2] = rx_valid[2] && rx_ready[2];
    assign push[3] = rx_valid[3] && rx_ready[3];
    assign push[4] = rx_valid[4] && rx_ready[4];

    // ------------------------------------------------------------------
    // 2. FIFO Pointer & Count Update
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < N_PORTS; i++) begin
                wr_ptr[i] <= '0;
                rd_ptr[i] <= '0;
                count[i]  <= '0;
            end
        end else begin
            for (int i = 0; i < N_PORTS; i++) begin
                if (push[i] && !pop[i]) begin
                    wr_ptr[i] <= wr_ptr[i] + 1'b1;
                    count[i]  <= count[i] + 1'b1;
                end else if (!push[i] && pop[i]) begin
                    rd_ptr[i] <= rd_ptr[i] + 1'b1;
                    count[i]  <= count[i] - 1'b1;
                end else if (push[i] && pop[i]) begin
                    wr_ptr[i] <= wr_ptr[i] + 1'b1;
                    rd_ptr[i] <= rd_ptr[i] + 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // 3. FIFO Storage Instances (GUARANTEED RAM INFERENCE)
    // ------------------------------------------------------------------
    logic [1:0]              rd_type_mux   [0:N_PORTS-1];
    logic [CORD_WIDTH-1:0]   rd_dest_x_mux [0:N_PORTS-1];
    logic [CORD_WIDTH-1:0]   rd_dest_y_mux [0:N_PORTS-1];
    logic [DATA_WIDTH-1:0]   rd_payload_mux[0:N_PORTS-1];

    genvar g;
    generate
        for (g = 0; g < N_PORTS; g++) begin : gen_port_fifo
            noc_fifo_storage #(
                .DATA_WIDTH(DATA_WIDTH),
                .CORD_WIDTH(CORD_WIDTH),
                .FIFO_DEPTH(FIFO_DEPTH)
            ) u_fifo_storage (
                .clk        (clk),
                .rst_n      (rst_n),
                .wr_en      (push[g]),
                .wr_addr    (wr_ptr[g]),
                .rd_addr    (rd_ptr[g]),
                .wr_type    (rx_flit_type[g]),
                .wr_dest_x  (rx_dest_x[g]),
                .wr_dest_y  (rx_dest_y[g]),
                .wr_payload (rx_payload[g]),
                .rd_type    (rd_type_mux[g]),
                .rd_dest_x  (rd_dest_x_mux[g]),
                .rd_dest_y  (rd_dest_y_mux[g]),
                .rd_payload (rd_payload_mux[g])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // 4. Packet Tracking
    // FIX NOC-P0-001: Set/Reset priority - all set logic nested inside else{}
    // ------------------------------------------------------------------
    logic [CORD_WIDTH-1:0] active_dest_x [N_PORTS-1:0];
    logic [CORD_WIDTH-1:0] active_dest_y [N_PORTS-1:0];
    logic                  packet_active [N_PORTS-1:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < N_PORTS; i++) begin
                active_dest_x[i]  <= '0;
                active_dest_y[i]  <= '0;
                packet_active[i]  <= 1'b0;
            end
        end else begin
            // FIX NOC-P0-001: Set logic nested in else{} - reset has priority
            if (|pop) begin
                for (int i = 0; i < N_PORTS; i++) begin
                    if (pop[i]) begin
                        case (rd_type_mux[i])
                            2'b00: begin
                                active_dest_x[i] <= rd_dest_x_mux[i];
                                active_dest_y[i] <= rd_dest_y_mux[i];
                                packet_active[i] <= 1'b1;
                            end
                            2'b10, 2'b11: begin
                                packet_active[i] <= 1'b0;
                            end
                            default: begin
                                // BODY flit - keep state unchanged
                            end
                        endcase
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // 5. XY Routing Request Matrix (combinational)
    // ------------------------------------------------------------------
    logic [N_PORTS-1:0][4:0] req_matrix;

    always_comb begin
        integer i;
        logic [CORD_WIDTH-1:0] dx, dy;

        req_matrix = '0;
        for (i = 0; i < N_PORTS; i++) begin
            if (count[i] > 0) begin
                if (packet_active[i]) begin
                    dx = active_dest_x[i];
                    dy = active_dest_y[i];
                end else begin
                    dx = rd_dest_x_mux[i];
                    dy = rd_dest_y_mux[i];
                end
                if      (dx > my_x) req_matrix[i][EAST]  = 1'b1;
                else if (dx < my_x) req_matrix[i][WEST]  = 1'b1;
                else if (dy > my_y) req_matrix[i][NORTH] = 1'b1;
                else if (dy < my_y) req_matrix[i][SOUTH] = 1'b1;
                else                req_matrix[i][LOCAL]  = 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // 6. Round-Robin Arbitration
    // ------------------------------------------------------------------
    logic [2:0] priority_reg [0:N_PORTS-1];
    logic [N_PORTS-1:0] grant_valid;
    logic [2:0] grant_idx [0:N_PORTS-1];

    always_comb begin
        integer out_p, j;
        logic [2:0] candidate;

        grant_valid = '0;
        grant_idx = '{default: '0};

        for (out_p = 0; out_p < N_PORTS; out_p++) begin
            for (j = 0; j < N_PORTS; j++) begin
                candidate = (priority_reg[out_p] + 3'(j)) % N_PORTS;
                if (!grant_valid[out_p] && req_matrix[candidate][out_p]) begin
                    grant_valid[out_p] = 1'b1;
                    grant_idx[out_p]   = candidate;
                end
            end
        end
    end

    logic [N_PORTS-1:0] out_ready;
    assign out_ready[LOCAL] = local_ready;
    assign out_ready[NORTH] = tx_ready[NORTH];
    assign out_ready[SOUTH] = tx_ready[SOUTH];
    assign out_ready[EAST]  = tx_ready[EAST];
    assign out_ready[WEST]  = tx_ready[WEST];

    // ------------------------------------------------------------------
    // 7. Pop Request Generation
    // ------------------------------------------------------------------
    logic [N_PORTS-1:0] pop_next;

    always_comb begin
        integer out_p;
        pop_next = '0;
        for (out_p = 0; out_p < N_PORTS; out_p++) begin
            if (grant_valid[out_p] && out_ready[out_p]) begin
                pop_next[grant_idx[out_p]] = 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // 8. Crossbar Output & Priority Update
    // FIX NOC-P0-001: tx_payload/flit_type assignments nested in else{}
    // so reset unconditionally clears, and set only when not in reset.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_valid      <= '0;
            tx_payload    <= '0;
            tx_flit_type  <= '0;
            local_valid   <= 1'b0;
            local_payload <= '0;
            local_flit_type <= 2'b0;
            pop           <= '0;
            priority_reg  <= '{default: '0};
        end else begin
            // FIX NOC-P0-001: All assignments inside else{} - reset has priority
            pop         <= pop_next;
            tx_valid    <= '0;
            tx_payload  <= '0;
            tx_flit_type <= '0;
            local_valid <= 1'b0;
            local_payload   <= '0;
            local_flit_type <= 2'b0;

            for (int out_p = 0; out_p < N_PORTS; out_p++) begin
                if (grant_valid[out_p] && out_ready[out_p]) begin
                    if (out_p == LOCAL) begin
                        local_valid     <= 1'b1;
                        local_payload   <= rd_payload_mux[grant_idx[out_p]];
                        local_flit_type <= rd_type_mux[grant_idx[out_p]];
                    end else begin
                        tx_valid[out_p]     <= 1'b1;
                        tx_payload[out_p]   <= rd_payload_mux[grant_idx[out_p]];
                        tx_flit_type[out_p] <= rd_type_mux[grant_idx[out_p]];
                    end
                    priority_reg[out_p] <= (grant_idx[out_p] + 3'd1) % N_PORTS;
                end
            end
        end
    end

endmodule


// =========================================================================
// HELPER MODULE: Strict 1D FIFO Storage for GUARANTEED LUTRAM Inference
// =========================================================================
module noc_fifo_storage #(
    parameter DATA_WIDTH = 64,
    parameter CORD_WIDTH = 4,
    parameter FIFO_DEPTH = 4
)(
    input logic clk, rst_n,
    input logic wr_en,
    input logic [$clog2(FIFO_DEPTH)-1:0] wr_addr,
    input logic [$clog2(FIFO_DEPTH)-1:0] rd_addr,
    input logic [1:0] wr_type,
    input logic [CORD_WIDTH-1:0] wr_dest_x,
    input logic [CORD_WIDTH-1:0] wr_dest_y,
    input logic [DATA_WIDTH-1:0] wr_payload,
    output logic [1:0] rd_type,
    output logic [CORD_WIDTH-1:0] rd_dest_x,
    output logic [CORD_WIDTH-1:0] rd_dest_y,
    output logic [DATA_WIDTH-1:0] rd_payload
);
    (* ram_style = "distributed" *) logic [1:0]            mem_type    [0:FIFO_DEPTH-1];
    (* ram_style = "distributed" *) logic [CORD_WIDTH-1:0] mem_dest_x  [0:FIFO_DEPTH-1];
    (* ram_style = "distributed" *) logic [CORD_WIDTH-1:0] mem_dest_y  [0:FIFO_DEPTH-1];
    (* ram_style = "distributed" *) logic [DATA_WIDTH-1:0] mem_payload [0:FIFO_DEPTH-1];

    always_ff @(posedge clk) begin
        if (wr_en) begin
            mem_type[wr_addr]    <= wr_type;
            mem_dest_x[wr_addr]  <= wr_dest_x;
            mem_dest_y[wr_addr]  <= wr_dest_y;
            mem_payload[wr_addr] <= wr_payload;
        end
    end

    assign rd_type    = mem_type[rd_addr];
    assign rd_dest_x  = mem_dest_x[rd_addr];
    assign rd_dest_y  = mem_dest_y[rd_addr];
    assign rd_payload = mem_payload[rd_addr];

endmodule