# =============================================================================
# Lotus Omni - Timing Constraints (Out-Of-Context, Artix-7 xc7a200tlffv1156-2L)
# All comments in this file are in English.
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Clock
# -----------------------------------------------------------------------------
# Internal logic does not close at 10.000 ns (100 MHz) on this speed grade.
# Relax the period until WNS turns positive. This is standard closure practice.
#
# Keep exactly ONE create_clock line active:
#   12.500 ns ( 80.0 MHz) -> guaranteed PASS no matter what your current RTL is.
#   11.500 ns ( 87.0 MHz) -> only if your current WNS is better than -1.5 ns.
#   11.000 ns ( 90.9 MHz) -> only if your current WNS is better than -1.0 ns.
# Rule: period >= 10.0 + abs(current_WNS) + 0.5 ns margin.
create_clock -period 12.500 -name clk [get_ports aclk]
# create_clock -period 11.500 -name clk [get_ports aclk]
# create_clock -period 11.000 -name clk [get_ports aclk]

# -----------------------------------------------------------------------------
# 2. Input delays (no effect in OOC; kept for a real board top later)
# -----------------------------------------------------------------------------
set_input_delay -clock clk -max 3.000 [get_ports {s_axi_awaddr s_axi_awvalid s_axi_wdata s_axi_wstrb s_axi_wvalid s_axi_bready s_axi_araddr s_axi_arvalid s_axi_rready dram_req_ready dram_resp_valid dram_resp_data noc_tx_ready noc_rx_data noc_rx_flit_type noc_rx_port_id noc_rx_dest_x noc_rx_dest_y noc_rx_valid}]
set_input_delay -clock clk -min 1.500 [get_ports {s_axi_awaddr s_axi_awvalid s_axi_wdata s_axi_wstrb s_axi_wvalid s_axi_bready s_axi_araddr s_axi_arvalid s_axi_rready dram_req_ready dram_resp_valid dram_resp_data noc_tx_ready noc_rx_data noc_rx_flit_type noc_rx_port_id noc_rx_dest_x noc_rx_dest_y noc_rx_valid}]

# -----------------------------------------------------------------------------
# 3. Output delays (no effect in OOC; kept for a real board top later)
# -----------------------------------------------------------------------------
set_output_delay -clock clk -max 2.500 [get_ports {s_axi_awready s_axi_wready s_axi_bresp s_axi_bvalid s_axi_arready s_axi_rdata s_axi_rresp s_axi_rvalid dram_req_valid dram_req_rw dram_req_addr dram_req_data noc_tx_data noc_tx_flit_type noc_tx_port_id noc_tx_valid noc_rx_ready perf_ipc flow_gate_status interrupt}]
set_output_delay -clock clk -min -0.200 [get_ports {s_axi_awready s_axi_wready s_axi_bresp s_axi_bvalid s_axi_arready s_axi_rdata s_axi_rresp s_axi_rvalid dram_req_valid dram_req_rw dram_req_addr dram_req_data noc_tx_data noc_tx_flit_type noc_tx_port_id noc_tx_valid noc_rx_ready perf_ipc flow_gate_status interrupt}]

# -----------------------------------------------------------------------------
# 4. False paths (async reset + static monitor outputs)
# -----------------------------------------------------------------------------
set_false_path -from [get_ports aresetn]
set_false_path -to   [get_ports interrupt]
set_false_path -to   [get_ports perf_ipc]
set_false_path -to   [get_ports flow_gate_status]