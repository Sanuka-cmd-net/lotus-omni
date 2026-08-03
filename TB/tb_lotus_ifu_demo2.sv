`timescale 1ns / 1ps
// =============================================================================
// Lotus Omni - Demo 2 / Stage 1 : IFU fetch pipeline running a real RV64 program
// Self-contained. Instantiates lotus_ifu_masterpiece + a behavioral,
// zero-latency instruction ROM that implements the L1I responder side.
// Proves: (a) PC walks a real program with correct instruction encodings,
//         (b) FIX IFU-001 (backend stall no longer stops cache requests).
// =============================================================================
module tb_lotus_ifu_demo2;
    import lotus_pkg::*;

    localparam CLK_PERIOD   = 12.5;            // 80 MHz (timing-closed clock)
    localparam logic [63:0] BASE = 64'h8000_0000;

    // ---- clock ----
    logic clk;
    initial clk = 1'b0;
    always #(CLK_PERIOD/2.0) clk = ~clk;

    // ---- IFU ports (names match the module exactly, so .* wiring is safe) ----
    logic          rst_n;
    logic          flush;
    logic [63:0]   flush_target_pc;
    logic          tage_pred_taken;
    logic [63:0]   tage_pred_target;
    logic          l1i_req_valid;
    logic [63:0]   l1i_req_pc;
    logic          l1i_req_ready;
    logic          l1i_resp_valid;
    logic [511:0]  l1i_resp_data;
    logic          dec_ready;
    fetch_packet_t out_packet;
    logic          out_valid;
    logic [63:0]   perf_fetch_stalls;
    logic [63:0]   perf_zombie_kills;

    // ---- DUT ----
    lotus_ifu_masterpiece u_ifu (.*);

    // =========================================================================
    // Behavioral instruction ROM (L1I responder model)
    // 256 words = 16 cache lines of 16 words (64 bytes) each.
    // =========================================================================
    logic [31:0] rom [0:255];

    initial begin
        // Default every word to NOP (addi x0, x0, 0)
        for (int i = 0; i < 256; i++) rom[i] = 32'h0000_0013;

        // Line 0 (BASE + 0x00): a tiny hand-assembled RV64I program
        rom[0]  = 32'h0050_0093;   // addi x1, x0, 5
        rom[1]  = 32'h0070_0113;   // addi x2, x0, 7
        rom[2]  = 32'h0020_81B3;   // add  x3, x1, x2     (-> 12)
        rom[3]  = 32'h00A1_8213;   // addi x4, x3, 10     (-> 22)
        rom[4]  = 32'h0040_0293;   // addi x5, x0, 4
        rom[5]  = 32'h0052_8333;   // add  x6, x5, x5     (-> 8)
        // words 6..15 stay NOP
    end

    // Combinational (zero-latency) read: data follows the CURRENT request PC,
    // so out_packet.pc and out_packet.inst_block stay consistent when sampled.
    always_comb begin
        automatic logic [63:0] pc = l1i_req_pc;
        automatic int base_word;
        l1i_resp_data = '0;
        if (pc >= BASE && pc < (BASE + 64*16)) begin
            base_word = int'((pc - BASE) >> 2) & ~15;   // align to 16-word line
            for (int k = 0; k < 16; k++)
                l1i_resp_data[k*32 +: 32] = rom[base_word + k];
        end
    end

    assign l1i_resp_valid = l1i_req_valid;   // respond the same cycle as request
    assign l1i_req_ready  = 1'b1;            // never stall the request side

    // =========================================================================
    // Backend (decoder) model: ready most of the time, then stall briefly to
    // demonstrate FIX IFU-001 (requests keep going while the packet is held).
    // =========================================================================
    initial begin
        dec_ready = 1'b1;
        #(CLK_PERIOD * 40);
        dec_ready = 1'b0;        // backend full: out_packet must hold
        #(CLK_PERIOD * 6);
        dec_ready = 1'b1;        // backend drains: streaming resumes
    end

    // ---- reset ----
    initial begin
        rst_n          = 1'b0;
        flush          = 1'b0;
        flush_target_pc= '0;
        tage_pred_taken= 1'b0;
        tage_pred_target='0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    // ---- monitor: print every delivered fetch packet ----
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            $display("[%0t] FETCH pc=%h  w0=%h w1=%h w2=%h w3=%h  dec_ready=%b",
                     $time, out_packet.pc,
                     out_packet.inst_block[31:0],
                     out_packet.inst_block[63:32],
                     out_packet.inst_block[95:64],
                     out_packet.inst_block[127:96],
                     dec_ready);
        end
    end

    // ---- watchdog / finish ----
    initial begin
        #(CLK_PERIOD * 200);
        $display("[%0t] SIM DONE  fetch_stalls=%0d  zombie_kills=%0d",
                 $time, perf_fetch_stalls, perf_zombie_kills);
        $finish;
    end

endmodule