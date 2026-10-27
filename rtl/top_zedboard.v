// Top level of the anti-replay engine for the ZedBoard (xc7z020clg484-1).
// top_zedboard_ps.v wraps it when the PC link goes through the ARM processor.
//
// PC --UART--> frame_parser --> auth_stage (SipHash-2-4)
//   data frame  --> strict_counter and sliding_window in parallel
//               --> decision_control (policy from SW0, final verdict, command, counters)
//   reset frame --> accepted only with a valid reset tag AND an epoch higher than
//                   the last one, then clears both engines and the counters
//   --> telemetry (UART text), led_display (LEDs), oled_status + oled_ssd1306 (OLED)
//
// BTNC also starts a new session. It needs physical access, so it is not signed.
// The frames A5 E1 and A5 E0 let the host show an overall test PASS or FAIL.
module top_zedboard #(
    parameter W               = 64,
    parameter CLK_HZ          = 100_000_000,
    parameter BAUD            = 115_200,
    parameter TIMEOUT_CYCLES  = 1_000_000,   // 10 ms gap abandons a frame
    parameter DEBOUNCE_CYCLES = 1_000_000,   // 10 ms button debounce
    parameter LED_TICK_CYCLES = 12_500_000   // 125 ms per LED and OLED display step
) (
    input  wire       clk,
    input  wire       btn_c,
    input  wire       sw_policy,   // SW0: 0 = strict counter, 1 = sliding window
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [7:0] led,
    output wire       oled_sdin,
    output wire       oled_sclk,
    output wire       oled_dc,
    output wire       oled_res,
    output wire       oled_vbat,
    output wire       oled_vdd
);
    localparam CLKS_PER_BIT = CLK_HZ / BAUD;

    // Power-on reset: hold everything in reset for the first 16 clocks.
    reg [3:0] por_cnt = 4'd0;
    wire      rst = ~&por_cnt;
    always @(posedge clk)
        if (rst) por_cnt <= por_cnt + 4'd1;

    // Button: synchronize, debounce, then make a one-clock pulse on press.
    reg        btn_s1 = 1'b0, btn_s2 = 1'b0, btn_stable = 1'b0, btn_stable_d = 1'b0;
    reg [31:0] btn_cnt = 32'd0;
    always @(posedge clk) begin
        btn_s1       <= btn_c;
        btn_s2       <= btn_s1;
        btn_stable_d <= btn_stable;
        if (btn_s2 == btn_stable) begin
            btn_cnt <= 32'd0;
        end else if (btn_cnt == DEBOUNCE_CYCLES - 1) begin
            btn_stable <= btn_s2;
            btn_cnt    <= 32'd0;
        end else begin
            btn_cnt <= btn_cnt + 32'd1;
        end
    end
    wire btn_press = btn_stable && !btn_stable_d;

    // Policy switch: a slide switch, so two flip-flops are enough.
    reg pol_s1 = 1'b0, policy_sw = 1'b0;
    always @(posedge clk) begin
        pol_s1    <= sw_policy;
        policy_sw <= pol_s1;
    end

    // UART receive and framing.
    wire [7:0]   rx_data;
    wire         rx_valid, rx_err;
    wire [127:0] frame;
    wire         frame_valid, frame_is_reset, parse_err, host_pass, host_fail;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst(rst), .rx(uart_rx),
        .data(rx_data), .valid(rx_valid), .frame_err(rx_err)
    );

    frame_parser #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) u_parser (
        .clk(clk), .rst(rst), .byte_valid(rx_valid), .byte_data(rx_data), .byte_err(rx_err),
        .frame_valid(frame_valid), .frame(frame), .frame_is_reset(frame_is_reset),
        .host_pass(host_pass), .host_fail(host_fail), .parse_err(parse_err)
    );

    // Authentication. keep_hierarchy stops Vivado moving logic across the
    // measured module boundaries, so the per-module utilization numbers hold.
    wire        auth_done, mac_ok, is_reset;
    wire [31:0] seq;
    wire [15:0] payload;
    (* keep_hierarchy = "yes" *)
    auth_stage u_auth (
        .clk(clk), .rst(rst), .frame_valid(frame_valid), .frame_is_reset(frame_is_reset),
        .pkt(frame), .auth_done(auth_done), .mac_ok(mac_ok), .is_reset(is_reset),
        .seq(seq), .payload(payload)
    );

    // Signed reset: the tag must be valid and the epoch must be higher than the
    // last accepted one, so neither a forged nor a replayed reset is accepted.
    reg  [31:0] last_epoch;
    wire        reset_frame  = auth_done && is_reset;
    wire        reset_ok     = reset_frame && mac_ok && (seq > last_epoch);
    wire        reset_denied = reset_frame && !reset_ok;
    wire        session_clear = reset_ok || btn_press;
    always @(posedge clk)
        if (rst)           last_epoch <= 32'd0;
        else if (reset_ok) last_epoch <= seq;

    wire data_done = auth_done && !is_reset;

    wire strict_valid, strict_accept;
    (* keep_hierarchy = "yes" *)
    strict_counter u_strict (
        .clk(clk), .rst(rst), .clear(session_clear),
        .in_valid(data_done), .mac_ok(mac_ok), .seq(seq),
        .out_valid(strict_valid), .accept(strict_accept)
    );

    wire       window_valid, window_accept;
    wire [2:0] window_reason;
    (* keep_hierarchy = "yes" *)
    sliding_window #(.W(W)) u_window (
        .clk(clk), .rst(rst), .clear(session_clear),
        .in_valid(data_done), .mac_ok(mac_ok), .seq(seq),
        .out_valid(window_valid), .accept(window_accept), .reason(window_reason)
    );

    // Decision & Control: one final verdict under the selected policy.
    wire        decision_valid, policy_used, final_accept, door_open;
    wire [15:0] sc_acc, sc_rej, sw_acc, sw_rej;
    (* keep_hierarchy = "yes" *)
    decision_control u_decide (
        .clk(clk), .rst(rst), .policy_sw(policy_sw), .session_clear(session_clear),
        .verdict_valid(window_valid), .mac_ok(mac_ok),
        .strict_accept(strict_accept), .window_accept(window_accept), .cmd(payload),
        .decision_valid(decision_valid), .policy(policy_used), .final_accept(final_accept),
        .door_open(door_open), .sc_acc(sc_acc), .sc_rej(sc_rej), .sw_acc(sw_acc), .sw_rej(sw_rej)
    );

    // Latency: clocks from frame_valid to the final decision.
    reg [15:0] lat_cnt;
    reg [15:0] verdict_count;
    always @(posedge clk) begin
        if (rst) begin
            lat_cnt       <= 16'd0;
            verdict_count <= 16'd0;
        end else begin
            if (frame_valid)
                lat_cnt <= 16'd1;
            else if (lat_cnt != 16'hFFFF)
                lat_cnt <= lat_cnt + 16'd1;
            if (decision_valid)
                verdict_count <= verdict_count + 16'd1;
        end
    end

    telemetry #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tel (
        .clk(clk), .rst(rst),
        .verdict_valid(decision_valid), .seq(seq), .cmd(payload), .mac_ok(mac_ok),
        .strict_accept(strict_accept), .window_accept(window_accept),
        .window_reason(window_reason), .policy(reset_frame ? policy_sw : policy_used),
        .final_accept(final_accept), .door_open(door_open),
        .latency(lat_cnt), .count(verdict_count + 16'd1),
        .sc_acc(sc_acc), .sc_rej(sc_rej), .sw_acc(sw_acc), .sw_rej(sw_rej),
        .reset_ok(reset_ok), .reset_denied(reset_denied), .reset_button(btn_press),
        .error_event(parse_err),
        .tx(uart_tx)
    );

    led_display #(.TICK_CYCLES(LED_TICK_CYCLES)) u_leds (
        .clk(clk), .rst(rst),
        .verdict_valid(decision_valid), .mac_ok(mac_ok),
        .strict_accept(strict_accept), .window_accept(window_accept),
        .window_reason(window_reason),
        .session_clear(session_clear), .parse_err(parse_err | reset_denied),
        .host_pass(host_pass), .host_fail(host_fail),
        .led(led)
    );

    wire [1:0] oled_row;
    wire [3:0] oled_col;
    wire [6:0] oled_ch;
    oled_status #(.W(W), .TICK_CYCLES(LED_TICK_CYCLES)) u_oled_text (
        .clk(clk), .rst(rst),
        .verdict_valid(decision_valid), .mac_ok(mac_ok),
        .strict_accept(strict_accept), .window_accept(window_accept),
        .window_reason(window_reason), .policy_used(policy_used), .final_accept(final_accept),
        .cmd(payload), .seq(seq), .door_open(door_open), .policy_live(policy_sw),
        .sc_acc(sc_acc), .sc_rej(sc_rej), .sw_acc(sw_acc), .sw_rej(sw_rej),
        .reset_ok(reset_ok), .reset_button(btn_press), .reset_denied(reset_denied),
        .parse_err(parse_err), .host_pass(host_pass), .host_fail(host_fail),
        .row(oled_row), .col(oled_col), .ch(oled_ch)
    );

    oled_ssd1306 #(.DELAY_1MS(CLK_HZ / 1000), .DELAY_100MS(CLK_HZ / 10)) u_oled (
        .clk(clk), .rst(rst), .row(oled_row), .col(oled_col), .ch(oled_ch),
        .sdin(oled_sdin), .sclk(oled_sclk), .dc(oled_dc),
        .res_n(oled_res), .vbat_n(oled_vbat), .vdd_n(oled_vdd)
    );
endmodule
