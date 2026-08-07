`timescale 1ns / 1ps
// =============================================================================
// Lotus Omni - Demo 3: Full Core (Scalar + Tensor, "AI Model Running")
// V3.1 FIX: Unrolled force/release statements (xsim forbids loop var in force)
// =============================================================================
module tb_lotus_core_demo3();

    localparam CLK_PERIOD = 10; // 100 MHz

    logic clk;
    logic rst_n;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // =========================================================================
    // Mock DRAM
    // =========================================================================
    logic          dram_req_valid;
    logic          dram_req_rw;
    logic [63:0]   dram_req_addr;
    logic [1023:0] dram_req_data;

    logic          dram_req_ready;
    logic          dram_resp_valid;
    logic [1023:0] dram_resp_data;

    logic [1023:0] mock_dram [0:127];

    // Tensor result self-checker
    int ten_total_count   = 0;
    int ten_correct_count = 0;
    localparam logic [31:0] EXPECTED_RESULT = 32'h00000030; // 2*3*8 = 48

    initial begin
        for (int i = 0; i < 128; i++) begin
            for (int w = 0; w < 32; w++) begin
                mock_dram[i][w*32 +: 32] = 32'h00000013; // NOP
            end
        end

        mock_dram[0][0*32   +: 32] = 32'h00500093;
        mock_dram[0][1*32   +: 32] = 32'h00700113;
        mock_dram[0][2*32   +: 32] = 32'h002081B3;
        mock_dram[0][3*32   +: 32] = 32'h00A18213;
        mock_dram[0][4*32   +: 32] = 32'h402202B3;
        mock_dram[0][5*32   +: 32] = 32'h06400313;
        mock_dram[0][6*32   +: 32] = 32'h005303B3;
        mock_dram[0][7*32   +: 32] = 32'h00000013;
    end

    // DRAM responder
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
    // DUT
    // =========================================================================
    lotus_omni_core_top_v2 u_dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .fetch_word_in        (32'h0),
        .fetch_word_idx       (4'h0),
        .fetch_word_valid     (1'b0),
        .fetch_pc_in          (64'h80000000),
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
    // Monitors
    // =========================================================================
    always @(posedge clk) begin
        if (rst_n && u_dut.u_ifu.l1i_req_valid)
            $display("[FETCH] %0t | PC = %h", $time, u_dut.u_ifu.l1i_req_pc);
    end

    always @(posedge clk) begin
        if (rst_n && u_dut.u_decoder.dispatch_valid)
            $display("[DISPATCH] %0t | valid = %b", $time, u_dut.u_decoder.dispatch_valid);
    end

    always @(posedge clk) begin
        if (rst_n && |u_dut.u_rs.issue_valid)
            $display("[ISSUE] %0t | valid = %b", $time, u_dut.u_rs.issue_valid);
    end

    always @(posedge clk) begin
        if (rst_n && |u_dut.u_alu.cdb_valid_out)
            $display("[CDB-ALU] %0t | valid = %b", $time, u_dut.u_alu.cdb_valid_out);
    end

    always @(posedge clk) begin
        if (rst_n && |u_dut.u_rob.commit_valid)
            $display("[COMMIT] %0t | valid = %b", $time, u_dut.u_rob.commit_valid);
    end

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

    always @(posedge clk) begin
        if (u_dut.ten_cdb_valid)
            $display("[CDB-TEN] %0t | PRF[%0d] = %h", $time, u_dut.ten_cdb_p_dest, u_dut.ten_cdb_data);
    end

    // Self-checker
    always @(posedge clk) begin
        if (u_dut.ten_cdb_valid) begin
            ten_total_count = ten_total_count + 1;
            if (u_dut.ten_cdb_data[31:0] == EXPECTED_RESULT)
                ten_correct_count = ten_correct_count + 1;
        end
    end

    always @(posedge clk) begin
        if (rst_n && dram_req_valid && dram_req_ready)
            $display("[DRAM] %0t | %s addr = %h", $time, dram_req_rw ? "WRITE" : "READ", dram_req_addr);
    end

    // =========================================================================
    // Test Sequence
    // =========================================================================
    initial begin
        $display("=========================================================");
        $display(" LOTUS OMNI - DEMO 3: FULL CORE (SCALAR + TENSOR)");
        $display("=========================================================");

        rst_n = 1'b0;
        #(CLK_PERIOD * 10);
        rst_n = 1'b1;
        $display("[%0t] Reset released. Scalar pipeline booting from DRAM...", $time);

        #(CLK_PERIOD * 100);

        // =====================================================================
        // Load tensor buffers DIRECTLY (unrolled - xsim forbids loop var)
        //   weights = 2, activations = 3
        // =====================================================================
        $display("\n[%0t] [TB] Loading tensor buffers directly...", $time);
        force u_dut.u_tensor_engine.weight_buf[0] = 128'h0002_0002_0002_0002_0002_0002_0002_0002;
        force u_dut.u_tensor_engine.weight_buf[1] = 128'h0002_0002_0002_0002_0002_0002_0002_0002;
        force u_dut.u_tensor_engine.weight_buf[2] = 128'h0002_0002_0002_0002_0002_0002_0002_0002;
        force u_dut.u_tensor_engine.weight_buf[3] = 128'h0002_0002_0002_0002_0002_0002_0002_0002;
        force u_dut.u_tensor_engine.weight_buf[4] = 128'h0002_0002_0002_0002_0002_0002_0002_0002;
        force u_dut.u_tensor_engine.weight_buf[5] = 128'h0002_0002_0002_0002_0002_0002_0002_0002;
        force u_dut.u_tensor_engine.weight_buf[6] = 128'h0002_0002_0002_0002_0002_0002_0002_0002;
        force u_dut.u_tensor_engine.weight_buf[7] = 128'h0002_0002_0002_0002_0002_0002_0002_0002;
        force u_dut.u_tensor_engine.act_buf[0]    = 128'h0003_0003_0003_0003_0003_0003_0003_0003;
        force u_dut.u_tensor_engine.act_buf[1]    = 128'h0003_0003_0003_0003_0003_0003_0003_0003;
        force u_dut.u_tensor_engine.act_buf[2]    = 128'h0003_0003_0003_0003_0003_0003_0003_0003;
        force u_dut.u_tensor_engine.act_buf[3]    = 128'h0003_0003_0003_0003_0003_0003_0003_0003;
        force u_dut.u_tensor_engine.act_buf[4]    = 128'h0003_0003_0003_0003_0003_0003_0003_0003;
        force u_dut.u_tensor_engine.act_buf[5]    = 128'h0003_0003_0003_0003_0003_0003_0003_0003;
        force u_dut.u_tensor_engine.act_buf[6]    = 128'h0003_0003_0003_0003_0003_0003_0003_0003;
        force u_dut.u_tensor_engine.act_buf[7]    = 128'h0003_0003_0003_0003_0003_0003_0003_0003;
        #(CLK_PERIOD * 2);

        // --- MATMUL injection ---
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

        // Release buffer forces (unrolled)
        release u_dut.u_tensor_engine.weight_buf[0];
        release u_dut.u_tensor_engine.weight_buf[1];
        release u_dut.u_tensor_engine.weight_buf[2];
        release u_dut.u_tensor_engine.weight_buf[3];
        release u_dut.u_tensor_engine.weight_buf[4];
        release u_dut.u_tensor_engine.weight_buf[5];
        release u_dut.u_tensor_engine.weight_buf[6];
        release u_dut.u_tensor_engine.weight_buf[7];
        release u_dut.u_tensor_engine.act_buf[0];
        release u_dut.u_tensor_engine.act_buf[1];
        release u_dut.u_tensor_engine.act_buf[2];
        release u_dut.u_tensor_engine.act_buf[3];
        release u_dut.u_tensor_engine.act_buf[4];
        release u_dut.u_tensor_engine.act_buf[5];
        release u_dut.u_tensor_engine.act_buf[6];
        release u_dut.u_tensor_engine.act_buf[7];

        // =====================================================================
        // Final self-check
        // =====================================================================
        $display("=========================================================");
        if (ten_total_count == 64 && ten_correct_count == 64) begin
            $display(" [CHECK] PASS: %0d/%0d tensor results == 0x%08h",
                     ten_correct_count, ten_total_count, EXPECTED_RESULT);
            $display(" [CHECK] Outer-product accumulation VERIFIED (2*3*8 = 48)");
        end else begin
            $display(" [CHECK] FAIL: %0d/%0d tensor results == 0x%08h (expected 64/64)",
                     ten_correct_count, ten_total_count, EXPECTED_RESULT);
        end
        $display("=========================================================");
        $display("[%0t] DEMO 3 COMPLETE: Scalar + Tensor finished!", $time);
        $display("=========================================================");
        $finish;
    end

endmodule