// ================================================================
// LOTUS OMNI - AXI4-Lite Wrapper - V2.0 TENSOR CDB CLEANUP
// ================================================================
// FIX WRAP-P0-001: All ports connected in u_core instantiation
//   - fetch_word_in, fetch_word_idx, fetch_bundle_commit → tied 0
//   - fetch_ready → left open (output, safe to leave open)
//   - noc_tx_* (5 ports) → connected to internal wires
//   - noc_rx_* (7 ports) → connected from wrapper ports
//
// FIX WRAP-TENSOR-001: Removed external tensor_cdb_* ports entirely.
//   Tensor CDB writeback is now handled internally by
//   lotus_tensor_engine inside lotus_omni_core_top_v2 - there is no
//   external tensor coprocessor, so these ports were dangling and
//   caused a port-mismatch synthesis error (Synth 8-11365) once the
//   core's tensor_cdb_* ports were made internal-only.
// ================================================================

module lotus_axi4_wrapper #(
    parameter integer C_S_AXI_DATA_WIDTH = 64,
    parameter integer C_S_AXI_ADDR_WIDTH = 32
)(
    // Clock and Reset
    input  logic         aclk,
    input  logic         aresetn,

    // =========================================================
    // AXI4-Lite Slave Interface
    // =========================================================
    input  logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic         s_axi_awvalid,
    output logic         s_axi_awready,
    input  logic [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    input  logic [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  logic         s_axi_wvalid,
    output logic         s_axi_wready,
    output logic [1:0]   s_axi_bresp,
    output logic         s_axi_bvalid,
    input  logic         s_axi_bready,
    input  logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic         s_axi_arvalid,
    output logic         s_axi_arready,
    output logic [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    output logic [1:0]   s_axi_rresp,
    output logic         s_axi_rvalid,
    input  logic         s_axi_rready,

    // =========================================================
    // DRAM Interface
    // =========================================================
    output logic          dram_req_valid,
    output logic          dram_req_rw,
    output logic [63:0]   dram_req_addr,
    output logic [1023:0] dram_req_data,
    input  logic          dram_req_ready,
    input  logic          dram_resp_valid,
    input  logic [1023:0] dram_resp_data,

    // =========================================================
    // NOC Interface (exposed at wrapper level)
    // =========================================================
    output logic [63:0]  noc_tx_data,
    output logic [1:0]   noc_tx_flit_type,
    output logic [2:0]   noc_tx_port_id,
    output logic         noc_tx_valid,
    input  logic         noc_tx_ready,

    input  logic [63:0]  noc_rx_data,
    input  logic [1:0]   noc_rx_flit_type,
    input  logic [2:0]   noc_rx_port_id,
    input  logic [3:0]   noc_rx_dest_x,
    input  logic [3:0]   noc_rx_dest_y,
    input  logic         noc_rx_valid,
    output logic         noc_rx_ready,

    // =========================================================
    // Performance & Status Outputs
    // =========================================================
    output logic [9:0]    perf_ipc,
    output logic [7:0]    flow_gate_status,
    output logic          interrupt
);

// =========================================================
// INTERNAL REGISTERS
// =========================================================
logic [31:0] slv_reg_ctrl;
logic [31:0] slv_reg_pc_low;
logic [31:0] slv_reg_pc_high;
logic [31:0] slv_reg_flow_ctrl;

logic aw_en;
logic axi_awready_reg;
logic axi_wready_reg;
logic axi_bvalid_reg;
logic axi_arready_reg;
logic axi_rvalid_reg;
logic [C_S_AXI_DATA_WIDTH-1:0] axi_rdata_reg;

logic [1:0]  bresp_reg;
logic [1:0]  rresp_reg;

// =========================================================
// INTERNAL STATUS WIRES (from core)
// =========================================================
logic [63:0] core_perf_ipc;
logic        core_active;
logic        core_exception;
logic [7:0]  core_flow_gate_status;
logic        core_flow_gate_throttled;

// =========================================================
// OUTPUT ASSIGNMENTS
// =========================================================
assign s_axi_bresp = bresp_reg;
assign s_axi_rresp = rresp_reg;

assign s_axi_awready = axi_awready_reg;
assign s_axi_wready  = axi_wready_reg;
assign s_axi_bvalid  = axi_bvalid_reg;
assign s_axi_arready = axi_arready_reg;
assign s_axi_rdata   = axi_rdata_reg;
assign s_axi_rvalid  = axi_rvalid_reg;

// =========================================================
// RESPONSE REGISTERS
// =========================================================
always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        bresp_reg <= 2'b00;
        rresp_reg <= 2'b00;
    end else begin
        bresp_reg <= 2'b00;
        rresp_reg <= 2'b00;
    end
end

// =========================================================
// AXI WRITE LOGIC
// =========================================================
always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        axi_awready_reg <= 1'b0;
        aw_en <= 1'b1;
    end else begin
        if (~axi_awready_reg && s_axi_awvalid && s_axi_wvalid && aw_en) begin
            axi_awready_reg <= 1'b1;
            aw_en <= 1'b0;
        end else if (s_axi_bready && axi_bvalid_reg) begin
            aw_en <= 1'b1;
            axi_awready_reg <= 1'b0;
        end else begin
            axi_awready_reg <= 1'b0;
        end
    end
end

always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        axi_wready_reg <= 1'b0;
    end else begin
        if (~axi_wready_reg && s_axi_wvalid && s_axi_awvalid && aw_en)
            axi_wready_reg <= 1'b1;
        else
            axi_wready_reg <= 1'b0;
    end
end

always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        slv_reg_ctrl       <= 32'h0;
        slv_reg_pc_low     <= 32'h8000_0000;
        slv_reg_pc_high    <= 32'h0000_0000;
        slv_reg_flow_ctrl  <= 32'h0000_0000;
    end else begin
        if (axi_wready_reg && s_axi_wvalid && axi_awready_reg && s_axi_awvalid) begin
            case (s_axi_awaddr[7:2])
                6'h00: slv_reg_ctrl      <= s_axi_wdata[31:0];
                6'h01: slv_reg_pc_low    <= s_axi_wdata[31:0];
                6'h02: slv_reg_pc_high   <= s_axi_wdata[31:0];
                6'h06: slv_reg_flow_ctrl <= s_axi_wdata[31:0];
                default: ;
            endcase
        end
    end
end

always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        axi_bvalid_reg <= 1'b0;
    end else begin
        if (axi_awready_reg && s_axi_awvalid && axi_wready_reg &&
            s_axi_wvalid && ~axi_bvalid_reg)
            axi_bvalid_reg <= 1'b1;
        else if (s_axi_bready && axi_bvalid_reg)
            axi_bvalid_reg <= 1'b0;
    end
end

// =========================================================
// AXI READ LOGIC
// =========================================================
always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        axi_arready_reg <= 1'b0;
    end else begin
        if (~axi_arready_reg && s_axi_arvalid)
            axi_arready_reg <= 1'b1;
        else if (axi_arready_reg && s_axi_arvalid && s_axi_arready)
            axi_arready_reg <= 1'b0;
    end
end

always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        axi_rvalid_reg <= 1'b0;
        axi_rdata_reg  <= 64'h0;
    end else begin
        if (axi_arready_reg && s_axi_arvalid && ~axi_rvalid_reg) begin
            axi_rvalid_reg <= 1'b1;
            case (s_axi_araddr[7:2])
                6'h00: axi_rdata_reg <= slv_reg_ctrl;
                6'h01: axi_rdata_reg <= slv_reg_pc_low;
                6'h02: axi_rdata_reg <= slv_reg_pc_high;
                6'h03: axi_rdata_reg <= {28'h0, core_flow_gate_throttled,
                                          core_exception, core_active};
                6'h04: axi_rdata_reg <= core_perf_ipc[31:0];
                6'h05: axi_rdata_reg <= core_perf_ipc[63:32];
                6'h06: axi_rdata_reg <= {16'h0, core_flow_gate_status,
                                          slv_reg_flow_ctrl[7:0]};
                6'h07: axi_rdata_reg <= {24'h0, core_flow_gate_status};
                default: axi_rdata_reg <= 32'h0;
            endcase
        end else if (axi_rvalid_reg && s_axi_rready) begin
            axi_rvalid_reg <= 1'b0;
        end
    end
end

// =========================================================
// GLITCH-FREE RESET SYNCHRONIZER
// =========================================================
logic async_soft_rst_n;
logic rst_sync_1, rst_sync_2;

assign async_soft_rst_n = aresetn & ~slv_reg_ctrl[1];

always_ff @(posedge aclk or negedge async_soft_rst_n) begin
    if (!async_soft_rst_n) begin
        rst_sync_1 <= 1'b0;
        rst_sync_2 <= 1'b0;
    end else begin
        rst_sync_1 <= 1'b1;
        rst_sync_2 <= rst_sync_1;
    end
end

logic core_rst_n;
assign core_rst_n = rst_sync_2;

// =========================================================
// FLOW CONTROL SIGNALS
// =========================================================
logic flow_gate_enable_int;
logic [7:0] global_throttle_limit_int;

assign flow_gate_enable_int      = slv_reg_flow_ctrl[0];
assign global_throttle_limit_int = slv_reg_flow_ctrl[15:8];

// =========================================================
// FIX WRAP-P0-001 / WRAP-TENSOR-001: INSTANTIATE THE LOTUS OMNI CORE
// Tensor CDB is now fully internal to the core (lotus_tensor_engine),
// so no tensor_cdb_* ports are connected here anymore.
// =========================================================
lotus_omni_core_top_v2 u_core (
    .clk                  (aclk),
    .rst_n                (core_rst_n),

    // Fetch interface - unused inputs tied to 0
    .fetch_pc_in          ({slv_reg_pc_high, slv_reg_pc_low}),
    .fetch_word_valid     (slv_reg_ctrl[0]),
    .fetch_word_in        (32'h0),
    .fetch_word_idx       (4'h0),
    .fetch_bundle_commit  (1'b0),
    .fetch_ready          (),

    // NOC TX - connected to wrapper output ports
    .noc_tx_data          (noc_tx_data),
    .noc_tx_flit_type     (noc_tx_flit_type),
    .noc_tx_port_id       (noc_tx_port_id),
    .noc_tx_valid         (noc_tx_valid),
    .noc_tx_ready         (noc_tx_ready),

    // NOC RX - connected from wrapper input ports
    .noc_rx_data          (noc_rx_data),
    .noc_rx_flit_type     (noc_rx_flit_type),
    .noc_rx_port_id       (noc_rx_port_id),
    .noc_rx_dest_x        (noc_rx_dest_x),
    .noc_rx_dest_y        (noc_rx_dest_y),
    .noc_rx_valid         (noc_rx_valid),
    .noc_rx_ready         (noc_rx_ready),

    // DRAM interface
    .dram_req_ready       (dram_req_ready),
    .dram_resp_valid      (dram_resp_valid),
    .dram_resp_data       (dram_resp_data),
    .dram_req_valid       (dram_req_valid),
    .dram_req_rw          (dram_req_rw),
    .dram_req_addr        (dram_req_addr),
    .dram_req_data        (dram_req_data),

    // Status outputs
    .perf_ipc             (core_perf_ipc),
    .core_active          (core_active),
    .exception_out        (core_exception),

    // Flow gate control
    .flow_gate_enable     (flow_gate_enable_int),
    .global_throttle_limit(global_throttle_limit_int),
    .flow_gate_status     (core_flow_gate_status),
    .flow_gate_throttled  (core_flow_gate_throttled)
);

// =========================================================
// PERFORMANCE & STATUS OUTPUT ASSIGNMENT
// =========================================================
assign perf_ipc         = core_perf_ipc[9:0];
assign flow_gate_status = core_flow_gate_status;
assign interrupt        = 1'b0;

endmodule