`timescale 1ns / 1ps
// =============================================================================
// Lotus Omni - Demo 3: Full Core (Scalar + Tensor, "AI Model Running")
// - Scalar: real RV64I program fetched from mock DRAM (IFU→L1I→L2→DRAM)
// - Tensor: WEIGHT_LOAD + MATMUL via direct injection (force commands)
// - Result: full core alive - fetch, decode, issue, execute, commit, tensor
// =============================================================================
module tb_lotus_core_demo3();

    // =========================================================================
    // 1. Clock and Reset
    // =========================================================================
    localparam CLK_PERIOD = 10; // 100 MHz

    logic clk;
    logic rst_n;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // =========================================================================
    // 2. Mock DRAM (16KB, 128 lines × 1024 bits)
    // =========================================================================
    logic          dram_req_valid;
    logic          dram_req_rw;
    logic [63:0]   dram_req_addr;
    logic [1023:0] dram_req_data;
    
    logic          dram_req_ready;
    logic          dram_resp_valid;
    logic [1023:0] dram_resp_data;

    logic [1023:0] mock_dram [0:127];

    initial begin
        // Default: NOPs everywhere
        for (int i = 0; i < 128; i++) begin
            for (int w = 0; w < 32; w++) begin
                mock_dram[i][w*32 +: 32] = 32'h00000013; // NOP
            end
        end

        // LINE 0 (address 0x0, PC 0x80000000): REAL RV64I PROGRAM
        mock_dram[0][0*32   +: 32] = 32'h00500093; // addi x1, x0, 5
        mock_dram[0][1*32   +: 32] = 32'h00700113; // addi x2, x0, 7
        mock_dram[0][2*32   +: 32] = 32'h002081B3; // add  x3, x1, x2  (x3=12)
        mock_dram[0][3*32   +: 32] = 32'h00A18213; // addi x4, x3, 10  (x4=22)
        mock_dram[0][4*32   +: 32] = 32'h402202B3; // sub  x5, x4, x2  (x5=15)
        mock_dram[0][5*32   +: 32] = 32'h06400313; // addi x6, x0, 100
        mock_dram[0][6*32   +: 32] = 32'h005303B3; // add  x7, x6, x5  (x7=115)
        mock_dram[0][7*32   +: 32] = 32'h00000013; // nop
        // words 8-15 stay NOP

        // LINE 8 (address 0x400 = 1024): TENSOR WEIGHTS (BF16 2.0 = 0x4000)
        for (int i = 0; i < 64; i++) mock_dram[8][i*16 +: 16] = 16'h4000;

        // LINE 16 (address 0x800 = 2048): TENSOR ACTIVATIONS (BF16 3.0 = 0x4040)
        for (int i = 0; i < 64; i++) mock_dram[16][i*16 +: 16] = 16'h4040;
    end

    // DRAM responder: 1-cycle latency, read-only
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dram_resp_valid <= 1'b0;
            dram_resp_data  <= '0;
            dram_req_ready  <= 1'b0;
        end else begin
            dram_req_ready <= 1'b1;
            if (dram_req_valid && dram_req_ready && !dram_req_rw) begin
                dram_resp_valid <= 1'b1;
                dram_resp_data  <= mock_dram[dram_req_addr[13:7]];
            end else begin
                dram_resp_valid <= 1'b0;
            end
        end
    end

    // =========================================================================
    // 3. DUT Instantiation
    // =========================================================================
    lotus_omni_core_top_v2 u_dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .fetch_word_in        (32'h0),        // tied off - scalar fetch via DRAM
        .fetch_word_idx       (4'h0),
        .fetch_word_valid     (1'b0),
        .fetch_pc_in          (64'h80000000), // start PC
        .fetch_bundle_commit  (1'b0),
        .fetch_ready          (),
        .noc_tx_data          (),
        .noc_tx_flit_type     (),
        .noc_tx_port_id       (),
        .noc_tx_valid         (),
        .noc_tx_ready         (1'b1),
        .noc_rx_data          (64'h0),
        .noc_rx_flit_type     (2'h0),
        .noc_rx_port_id       (3'h0),
        .noc_rx_dest_x        (4'h0),
        .noc_rx_dest_y        (4'h0),
        .noc_rx_valid         (1'b0),
        .noc_rx_ready         (),
        .dram_req_valid       (dram_req_valid),
        .dram_req_rw          (dram_req_rw),
        .dram_req_addr        (dram_req_addr),
        .dram_req_data        (dram_req_data),
        .dram_req_ready       (dram_req_ready),
        .dram_resp_valid      (dram_resp_valid),
        .dram_resp_data       (dram_resp_data),
        .perf_ipc             (),
        .core_active          (),
        .exception_out        (),
        .flow_gate_enable     (1'b1),
        .global_throttle_limit(8'hFF),
        .flow_gate_status     (),
        .flow_gate_throttled  ()
    );

    // =========================================================================
    // 4. Monitors - Scalar Pipeline + Tensor + DRAM
    // =========================================================================

    // --- Scalar: PC walk (IFU fetch) ---
    always @(posedge clk) begin
        if (rst_n && u_dut.u_ifu.l1i_req_valid) begin
            $display("[FETCH] %0t | PC = %h", $time, u_dut.u_ifu.l1i_req_pc);
        end
    end

    // --- Scalar: Dispatch ---
    always @(posedge clk) begin
        if (rst_n && u_dut.u_decoder.dispatch_valid) begin
            $display("[DISPATCH] %0t | valid = %b", $time, u_dut.u_decoder.dispatch_valid);
        end
    end

    // --- Scalar: Issue ---
    always @(posedge clk) begin
        if (rst_n && |u_dut.u_rs.issue_valid) begin
            $display("[ISSUE] %0t | valid = %b", $time, u_dut.u_rs.issue_valid);
        end
    end

    // --- Scalar: CDB writeback (ALU) ---
    always @(posedge clk) begin
        if (rst_n && |u_dut.u_alu.cdb_valid_out) begin
            $display("[CDB-ALU] %0t | valid = %b", $time, u_dut.u_alu.cdb_valid_out);
        end
    end

    // --- Scalar: Commit ---
    always @(posedge clk) begin
        if (rst_n && |u_dut.u_rob.commit_valid) begin
            $display("[COMMIT] %0t | valid = %b", $time, u_dut.u_rob.commit_valid);
        end
    end

    // --- Tensor: State machine ---
    logic [2:0] ten_prev_state;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ten_prev_state <= 3'b000;
        else begin
            if (u_dut.u_tensor_engine.state_r != ten_prev_state) begin
                case(u_dut.u_tensor_engine.state_r)
                    3'b000: $display("[TEN] %0t | State -> IDLE", $time);
                    3'b001: $display("[TEN] %0t | State -> LOAD_REQ", $time);
                    3'b010: $display("[TEN] %0t | State -> LOAD_WAIT", $time);
                    3'b011: $display("[TEN] %0t | State -> FEED", $time);
                    3'b100: $display("[TEN] %0t | State -> DRAIN", $time);
                    3'b101: $display("[TEN] %0t | State -> WRITEBACK (64 results)", $time);
                endcase
                ten_prev_state <= u_dut.u_tensor_engine.state_r;
            end
        end
    end

    // --- Tensor: CDB writeback ---
    always @(posedge clk) begin
        if (u_dut.ten_cdb_valid) begin
            $display("[CDB-TEN] %0t | PRF[%0d] = %h", $time, u_dut.ten_cdb_p_dest, u_dut.ten_cdb_data);
        end
    end

    // --- DRAM traffic ---
    always @(posedge clk) begin
        if (rst_n && dram_req_valid && dram_req_ready) begin
            $display("[DRAM] %0t | %s addr = %h", $time, dram_req_rw ? "WRITE" : "READ", dram_req_addr);
        end
    end

    // =========================================================================
    // 5. Test Sequence: Scalar Boot + Tensor Injection
    // =========================================================================
    initial begin
        $display("=========================================================");
        $display(" LOTUS OMNI - DEMO 3: FULL CORE (SCALAR + TENSOR)");
        $display("=========================================================");

        rst_n = 1'b0;
        #(CLK_PERIOD * 10);
        rst_n = 1'b1;
        $display("[%0t] Reset released. Scalar pipeline booting from DRAM...", $time);

        // Wait for scalar pipeline to fetch + execute instructions
        #(CLK_PERIOD * 100);

        // --- Tensor Injection 1: WEIGHT_LOAD ---
        $display("\n[%0t] [TB] Injecting WEIGHT_LOAD...", $time);
        force u_dut.u_tensor_engine.issue_valid = 1'b1;
        force u_dut.u_tensor_engine.issue_funct3 = 3'b000;
        force u_dut.u_tensor_engine.issue_base_addr = 64'd1024;
        force u_dut.u_tensor_engine.issue_precision = 2'b00;
        force u_dut.u_tensor_engine.issue_p_dest = 7'd10;
        #(CLK_PERIOD);
        release u_dut.u_tensor_engine.issue_valid;
        wait(u_dut.u_tensor_engine.state_r == 3'b000);
        #(CLK_PERIOD * 10);

        // --- Tensor Injection 2: MATMUL ---
        $display("\n[%0t] [TB] Injecting MATMUL...", $time);
        force u_dut.u_tensor_engine.issue_valid = 1'b1;
        force u_dut.u_tensor_engine.issue_funct3 = 3'b001;
        force u_dut.u_tensor_engine.issue_base_addr = 64'd2048;
        force u_dut.u_tensor_engine.issue_precision = 2'b00;
        force u_dut.u_tensor_engine.issue_p_dest = 7'd20;
        #(CLK_PERIOD);
        release u_dut.u_tensor_engine.issue_valid;
        wait(u_dut.u_tensor_engine.state_r == 3'b000);
        #(CLK_PERIOD * 50);

        $display("=========================================================");
        $display("[%0t] DEMO 3 COMPLETE: Scalar + Tensor finished!", $time);
        $display("=========================================================");
        $finish;
    end

endmodule