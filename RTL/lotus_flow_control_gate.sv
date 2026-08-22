`timescale 1ns / 1ps
// ================================================================
// LOTUS OMNI - Congestion-Aware Flow Control Gate (V2.3 - DEADLOCK FIX)
// ================================================================
// FIX V2.3: Bypassed aggressive credit lockups and flow gate stalls 
// to prevent core deadlock during high-traffic execution (CoreMark).
// ================================================================

module congestion_aware_flow_gate #(
    parameter DATA_WIDTH      = 512,
    parameter FIFO_DEPTH      = 4,
    parameter LOG2_FIFO_DEPTH = 2
)(
    input  logic clk,
    input  logic rst_n,

    input  logic                      upstream_valid,
    output logic                      upstream_ready,
    input  logic [DATA_WIDTH-1:0]     upstream_data,

    output logic                      downstream_valid,
    input  logic                      downstream_ready,
    output logic [DATA_WIDTH-1:0]     downstream_data,

    input  logic                      gate_enable,
    input  logic [7:0]                throttle_limit,
    input  logic [7:0]                max_outstanding,

    output logic                      gate_stalled,
    output logic [LOG2_FIFO_DEPTH:0]  fifo_count,
    output logic [7:0]                credit_count,
    output logic [7:0]                duty_cycle_actual
);

    // Distributed RAM for shallow depth
    (* ram_style = "distributed" *)
    logic [DATA_WIDTH-1:0] fifo_mem [0:FIFO_DEPTH-1];

    logic [LOG2_FIFO_DEPTH-1:0] fifo_wp;
    logic [LOG2_FIFO_DEPTH-1:0] fifo_rp;
    logic                       fifo_full, fifo_empty;

    logic [7:0] credit_count_int;
    logic [7:0] credit_consumed;
    logic [7:0] credit_freed;
    logic [7:0] throttle_counter;
    logic       throttle_tick;

    wire [LOG2_FIFO_DEPTH-1:0] next_wp = fifo_wp + 1;

    assign fifo_full  = (next_wp == fifo_rp);
    assign fifo_empty = (fifo_wp == fifo_rp);
    assign fifo_count = (fifo_wp >= fifo_rp) ?
                        (fifo_wp - fifo_rp) :
                        (FIFO_DEPTH - fifo_rp + fifo_wp);

    // =========================================================================
    // Throttle counter (Synchronous Reset)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            throttle_counter <= 8'h00;
            throttle_tick    <= 1'b0;
        end else if (gate_enable) begin
            throttle_counter <= (throttle_counter >= 8'hFF) ? 8'h00
                                                            : throttle_counter + 8'h01;
            if (throttle_limit == 8'h00)
                throttle_tick <= 1'b1;
            else
                throttle_tick <= (throttle_counter < throttle_limit);
        end else begin
            throttle_counter <= 8'h00;
            throttle_tick    <= 1'b0;
        end
    end

    // FIX V2.3: Deadlock-free upstream_ready assignment (allows flow even if credits peak)
    assign upstream_ready  = gate_enable && !fifo_full && 
                             ((credit_count_int < max_outstanding) || (credit_count_int == 8'h00) || throttle_tick);

    assign gate_stalled    = gate_enable && (credit_count_int >= max_outstanding) && fifo_full && !throttle_tick;

    assign credit_consumed = (upstream_valid && upstream_ready)   ? 8'h01 : 8'h00;
    assign credit_freed    = (downstream_valid && downstream_ready) ? 8'h01 : 8'h00;

    // =========================================================================
    // Credit counter (Synchronous Reset)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) credit_count_int <= 8'h00;
        else        credit_count_int <= credit_count_int + credit_consumed - credit_freed;
    end

    assign credit_count = credit_count_int;

    // =========================================================================
    // FIFO Write Logic (Synchronous Write)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fifo_wp <= '0;
        end else if (upstream_valid && upstream_ready) begin
            fifo_mem[fifo_wp] <= upstream_data;
            fifo_wp <= (fifo_wp == (FIFO_DEPTH - 1)) ? '0 : fifo_wp + 1;
        end
    end

    // =========================================================================
    // FIFO Read Logic (Combinational Read for LUTRAM)
    // =========================================================================
    logic downstream_read;
    assign downstream_read = downstream_valid && downstream_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fifo_rp <= '0;
        end else if (downstream_read) begin
            fifo_rp <= (fifo_rp == (FIFO_DEPTH - 1)) ? '0 : fifo_rp + 1;
        end
    end

    // Asynchronous read from LUTRAM
    assign downstream_data  = fifo_mem[fifo_rp];
    assign downstream_valid = !fifo_empty;

    // =========================================================================
    // Duty-cycle monitor
    // =========================================================================
    logic [15:0] cycle_count;
    logic [15:0] active_count;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cycle_count  <= '0;
            active_count <= '0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (upstream_valid && upstream_ready)
                active_count <= active_count + 1;
        end
    end

    assign duty_cycle_actual = (cycle_count > 16'h0100) ?
                               (active_count[7:0] >> 1) : 8'h00;

endmodule


// ================================================================
// MULTI-STAGE FLOW CONTROL GATE ARRAY
// ================================================================
module flow_gate_array #(
    parameter NUM_STAGES = 4,
    parameter DATA_WIDTH = 512,
    parameter FIFO_DEPTH = 4
)(
    input  logic clk,
    input  logic rst_n,
    input  logic [7:0] global_throttle,
    input  logic [7:0] max_credits_per_stage,
    input  logic [NUM_STAGES-1:0] stage_enable,
    input  logic [NUM_STAGES-1:0] stage_valid_in,
    output logic [NUM_STAGES-1:0] stage_ready_out,
    input  logic [DATA_WIDTH-1:0] stage_data_in [NUM_STAGES],
    output logic [NUM_STAGES-1:0] stage_valid_out,
    input  logic [NUM_STAGES-1:0] stage_ready_in,
    output logic [DATA_WIDTH-1:0] stage_data_out [NUM_STAGES],
    output logic [NUM_STAGES-1:0] stage_stalled,
    output logic [7:0] stage_fifo_count [NUM_STAGES]
);
    genvar i;
    generate
        for (i = 0; i < NUM_STAGES; i++) begin : gen_flow_gates
            congestion_aware_flow_gate #(
                .DATA_WIDTH(DATA_WIDTH),
                .FIFO_DEPTH(FIFO_DEPTH)
            ) stage_gate (
                .clk(clk), .rst_n(rst_n),
                .upstream_valid(stage_valid_in[i]),
                .upstream_ready(stage_ready_out[i]),
                .upstream_data(stage_data_in[i]),
                .downstream_valid(stage_valid_out[i]),
                .downstream_ready(stage_ready_in[i]),
                .downstream_data(stage_data_out[i]),
                .gate_enable(stage_enable[i]),
                .throttle_limit(global_throttle),
                .max_outstanding(max_credits_per_stage),
                .gate_stalled(stage_stalled[i]),
                .fifo_count(stage_fifo_count[i]),
                .credit_count(),
                .duty_cycle_actual()
            );
        end
    endgenerate
endmodule


// ================================================================
// GLOBAL THROTTLE CONTROLLER
// ================================================================
module global_throttle_controller (
    input  logic clk,
    input  logic rst_n,
    input  logic [15:0] current_lut_usage,
    input  logic [15:0] target_lut_usage,
    input  logic [15:0] max_lut_capacity,
    input  logic        auto_throttle_enable,
    input  logic [7:0]  manual_throttle_value,
    input  logic [7:0]  min_throttle,
    input  logic [7:0]  max_throttle,
    output logic [7:0]  global_throttle_out,
    output logic        throttle_active,
    output logic [7:0]  utilization_percent
);
    logic [15:0] error;
    logic [15:0] integral;
    logic [7:0]  adjustment;

    assign error = current_lut_usage - target_lut_usage;

    always_ff @(posedge clk) begin
        if (!rst_n) integral <= '0;
        else if (integral < 16'hFF00) integral <= integral + error[15:0];
    end

    assign adjustment = (error[15:8] > 0) ?
                        ((error[15:8] >> 2) + 8'h08) :
                        ((~error[15:8] + 1) >> 2) + 8'h04;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            global_throttle_out <= 8'h80;
            throttle_active     <= 1'b0;
        end else begin
            if (auto_throttle_enable) begin
                if (current_lut_usage > target_lut_usage) begin
                    global_throttle_out <= (global_throttle_out > min_throttle) ?
                                           (global_throttle_out - adjustment) : min_throttle;
                    throttle_active     <= 1'b1;
                end else begin
                    global_throttle_out <= (global_throttle_out < max_throttle) ?
                                           (global_throttle_out + (adjustment >> 1)) : max_throttle;
                    throttle_active     <= (global_throttle_out < max_throttle);
                end
            end else begin
                global_throttle_out <= manual_throttle_value;
                throttle_active     <= (manual_throttle_value < max_throttle);
            end
        end
    end

    // Multi-cycle Divider for Utilization Percent
    logic [31:0] div_dividend;
    logic [31:0] div_divisor;
    logic [31:0] div_quotient;
    logic [31:0] div_remainder;
    logic [6:0]  div_cnt;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            div_cnt      <= 7'd0;
            div_quotient <= 32'd0;
            div_remainder<= 32'd0;
            div_dividend <= 32'd0;
            div_divisor  <= 32'd0;
        end else begin
            if (div_cnt == 7'd0) begin
                div_dividend <= current_lut_usage * 32'd100;
                div_divisor  <= {16'd0, max_lut_capacity};
                div_remainder<= 32'd0;
                div_quotient <= 32'd0;
                div_cnt      <= 7'd32;
            end else begin
                if ({div_remainder[30:0], div_dividend[31]} >= div_divisor) begin
                    div_remainder <= {div_remainder[30:0], div_dividend[31]} - div_divisor;
                    div_quotient  <= {div_quotient[30:0], 1'b1};
                end else begin
                    div_remainder <= {div_remainder[30:0], div_dividend[31]};
                    div_quotient  <= {div_quotient[30:0], 1'b0};
                end
                div_dividend <= div_dividend << 1;
                div_cnt      <= div_cnt - 1'b1;
            end
        end
    end

    assign utilization_percent = div_quotient[7:0];

endmodule