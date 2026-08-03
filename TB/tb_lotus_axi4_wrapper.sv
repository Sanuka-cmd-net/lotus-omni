`timescale 1ns / 1ps
// ============================================================================
// Lotus Omni - AXI4-Lite Wrapper Testbench (Demo A)
// Purpose: prove reset, AXI4-Lite control plane, core boot, status readback,
//          and exception handling (core fetches all-zero words -> illegal
//          instruction -> exception). This is a "silicon alive" proof.
// Note: real instruction execution needs the core fetch port driven directly
//       (Demo B), because the wrapper ties fetch_word_in = 32'h0.
// ============================================================================
module tb_lotus_axi4_wrapper;

    // ------------------------------------------------------------------
    // Parameters (match the wrapper defaults)
    // ------------------------------------------------------------------
    localparam DW = 64;                 // AXI data width
    localparam AW = 32;                 // AXI address width
    localparam CLK_PERIOD = 12.5;       // 80 MHz (the timing-closed clock)

    // ------------------------------------------------------------------
    // Clock and reset
    // ------------------------------------------------------------------
    logic aclk;
    logic aresetn;

    initial aclk = 1'b0;
    always #(CLK_PERIOD/2.0) aclk = ~aclk;

    // ------------------------------------------------------------------
    // AXI4-Lite signals
    // ------------------------------------------------------------------
    logic [AW-1:0]     s_axi_awaddr;
    logic              s_axi_awvalid;
    logic              s_axi_awready;
    logic [DW-1:0]     s_axi_wdata;
    logic [DW/8-1:0]   s_axi_wstrb;
    logic              s_axi_wvalid;
    logic              s_axi_wready;
    logic [1:0]        s_axi_bresp;
    logic              s_axi_bvalid;
    logic              s_axi_bready;
    logic [AW-1:0]     s_axi_araddr;
    logic              s_axi_arvalid;
    logic              s_axi_arready;
    logic [DW-1:0]     s_axi_rdata;
    logic [1:0]        s_axi_rresp;
    logic              s_axi_rvalid;
    logic              s_axi_rready;

    // ------------------------------------------------------------------
    // DRAM interface (testbench acts as a simple always-ready responder)
    // ------------------------------------------------------------------
    logic              dram_req_valid;
    logic              dram_req_rw;
    logic [63:0]       dram_req_addr;
    logic [1023:0]     dram_req_data;
    logic              dram_req_ready;
    logic              dram_resp_valid;
    logic [1023:0]     dram_resp_data;

    // ------------------------------------------------------------------
    // NOC interface (TX always accepted, RX idle)
    // ------------------------------------------------------------------
    logic [63:0]       noc_tx_data;
    logic [1:0]        noc_tx_flit_type;
    logic [2:0]        noc_tx_port_id;
    logic              noc_tx_valid;
    logic              noc_tx_ready;
    logic [63:0]       noc_rx_data;
    logic [1:0]        noc_rx_flit_type;
    logic [2:0]        noc_rx_port_id;
    logic [3:0]        noc_rx_dest_x;
    logic [3:0]        noc_rx_dest_y;
    logic              noc_rx_valid;
    logic              noc_rx_ready;

    // ------------------------------------------------------------------
    // Status outputs
    // ------------------------------------------------------------------
    logic [9:0]        perf_ipc;
    logic [7:0]        flow_gate_status;
    logic              interrupt;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    lotus_axi4_wrapper #(
        .C_S_AXI_DATA_WIDTH (DW),
        .C_S_AXI_ADDR_WIDTH (AW)
    ) u_dut (
        .aclk               (aclk),
        .aresetn            (aresetn),
        // AXI write address channel
        .s_axi_awaddr       (s_axi_awaddr),
        .s_axi_awvalid      (s_axi_awvalid),
        .s_axi_awready      (s_axi_awready),
        // AXI write data channel
        .s_axi_wdata        (s_axi_wdata),
        .s_axi_wstrb        (s_axi_wstrb),
        .s_axi_wvalid       (s_axi_wvalid),
        .s_axi_wready       (s_axi_wready),
        // AXI write response channel
        .s_axi_bresp        (s_axi_bresp),
        .s_axi_bvalid       (s_axi_bvalid),
        .s_axi_bready       (s_axi_bready),
        // AXI read address channel
        .s_axi_araddr       (s_axi_araddr),
        .s_axi_arvalid      (s_axi_arvalid),
        .s_axi_arready      (s_axi_arready),
        // AXI read data channel
        .s_axi_rdata        (s_axi_rdata),
        .s_axi_rresp        (s_axi_rresp),
        .s_axi_rvalid       (s_axi_rvalid),
        .s_axi_rready       (s_axi_rready),
        // DRAM
        .dram_req_valid     (dram_req_valid),
        .dram_req_rw        (dram_req_rw),
        .dram_req_addr      (dram_req_addr),
        .dram_req_data      (dram_req_data),
        .dram_req_ready     (dram_req_ready),
        .dram_resp_valid    (dram_resp_valid),
        .dram_resp_data     (dram_resp_data),
        // NOC TX
        .noc_tx_data        (noc_tx_data),
        .noc_tx_flit_type   (noc_tx_flit_type),
        .noc_tx_port_id     (noc_tx_port_id),
        .noc_tx_valid       (noc_tx_valid),
        .noc_tx_ready       (noc_tx_ready),
        // NOC RX
        .noc_rx_data        (noc_rx_data),
        .noc_rx_flit_type   (noc_rx_flit_type),
        .noc_rx_port_id     (noc_rx_port_id),
        .noc_rx_dest_x      (noc_rx_dest_x),
        .noc_rx_dest_y      (noc_rx_dest_y),
        .noc_rx_valid       (noc_rx_valid),
        .noc_rx_ready       (noc_rx_ready),
        // Status
        .perf_ipc           (perf_ipc),
        .flow_gate_status   (flow_gate_status),
        .interrupt          (interrupt)
    );

    // ------------------------------------------------------------------
    // Simple environment drivers
    // ------------------------------------------------------------------
    // DRAM: always ready, never responds (enough for a boot/exception demo)
    assign dram_req_ready  = 1'b1;
    assign dram_resp_valid = 1'b0;
    assign dram_resp_data  = 1024'h0;

    // NOC: accept all TX, no RX traffic
    assign noc_tx_ready    = 1'b1;
    assign noc_rx_valid    = 1'b0;
    assign noc_rx_data     = 64'h0;
    assign noc_rx_flit_type= 2'h0;
    assign noc_rx_port_id  = 3'h0;
    assign noc_rx_dest_x   = 4'h0;
    assign noc_rx_dest_y   = 4'h0;

    // ------------------------------------------------------------------
    // AXI4-Lite write task
    // ------------------------------------------------------------------
    task automatic axi_write(input logic [AW-1:0] addr, input logic [DW-1:0] data);
        @(posedge aclk);
        s_axi_awaddr  <= addr;
        s_axi_awvalid <= 1'b1;
        s_axi_wdata   <= data;
        s_axi_wstrb   <= {(DW/8){1'b1}};
        s_axi_wvalid  <= 1'b1;
        s_axi_bready  <= 1'b1;
        // Wait until both address and data are accepted
        do @(posedge aclk); while (!(s_axi_awready && s_axi_wready));
        s_axi_awvalid <= 1'b0;
        s_axi_wvalid  <= 1'b0;
        // Wait for the write response
        do @(posedge aclk); while (!s_axi_bvalid);
        s_axi_bready  <= 1'b0;
    endtask

    // ------------------------------------------------------------------
    // AXI4-Lite read task
    // ------------------------------------------------------------------
    task automatic axi_read(input logic [AW-1:0] addr, output logic [DW-1:0] data);
        @(posedge aclk);
        s_axi_araddr  <= addr;
        s_axi_arvalid <= 1'b1;
        s_axi_rready  <= 1'b1;
        do @(posedge aclk); while (!s_axi_arready);
        s_axi_arvalid <= 1'b0;
        do @(posedge aclk); while (!s_axi_rvalid);
        data = s_axi_rdata;
        s_axi_rready  <= 1'b0;
    endtask

    // ------------------------------------------------------------------
    // Main stimulus
    // ------------------------------------------------------------------
    logic [DW-1:0] rd_data;

    initial begin
        // Initialise all TB-driven inputs
        aresetn       = 1'b0;
        s_axi_awaddr  = '0;  s_axi_awvalid = 1'b0;
        s_axi_wdata   = '0;  s_axi_wstrb   = '0;  s_axi_wvalid = 1'b0;
        s_axi_bready  = 1'b0;
        s_axi_araddr  = '0;  s_axi_arvalid = 1'b0;  s_axi_rready = 1'b0;

        // Hold reset for a while, then release
        repeat (20) @(posedge aclk);
        aresetn = 1'b1;
        $display("[%0t] Reset released", $time);
        repeat (10) @(posedge aclk);

        // ---- Enable the core + fetch: slv_reg_ctrl[0] = 1 (byte addr 0x00) ----
        // slv_reg_ctrl[1] is soft-reset (kept 0). [0] gates fetch_word_valid.
        axi_write(32'h0000_0000, 64'h0000_0000_0000_0001);
        $display("[%0t] Wrote slv_reg_ctrl = 0x1 (core+fetch enabled)", $time);

        // Let the core run: it fetches 0x00000000 words -> illegal instruction
        // -> exception logic should fire.
        repeat (100) @(posedge aclk);

        // ---- Read status register (byte addr 0x0C): {throttled, exception, active} ----
        axi_read(32'h0000_000C, rd_data);
        $display("[%0t] STATUS = 0x%016h  (active=%b exception=%b throttled=%b)",
                 $time, rd_data, rd_data[0], rd_data[1], rd_data[2]);

        // ---- Read perf_ipc low word (byte addr 0x10) ----
        axi_read(32'h0000_0010, rd_data);
        $display("[%0t] PERF_IPC_LOW = 0x%016h", $time, rd_data);

        // ---- Read flow-gate status (byte addr 0x1C) ----
        axi_read(32'h0000_001C, rd_data);
        $display("[%0t] FLOW_GATE_STATUS = 0x%016h", $time, rd_data);

        repeat (200) @(posedge aclk);
        $display("[%0t] SIM DONE", $time);
        $finish;
    end

    // ------------------------------------------------------------------
    // Watchdog (avoid infinite simulation if a handshake stalls)
    // ------------------------------------------------------------------
    initial begin
        #500_000;
        $display("[%0t] TIMEOUT - simulation killed by watchdog", $time);
        $finish;
    end

endmodule