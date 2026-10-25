// Top level for the ZedBoard (xc7z020clg484-1), FPGA logic only, no ARM.
//
// PC --USB--> Pmod USBUART on JA --uart_rx--> frame_parser --> auth_stage
//   --> strict_counter and sliding_window in parallel --> LEDs and telemetry --> PC
//
// LEDs, held until the next packet:
//   0 frame received (toggles)   1 MAC ok           2 MAC failed
//   3 strict engine accepted     4 window accepted  5 window duplicate
//   6 window stale               7 heartbeat (design is running)
// BTNC, or the frame A5 C3, starts a new replay test session.
module top_zedboard #(
    parameter W               = 64,
    parameter CLK_HZ          = 100_000_000,
    parameter BAUD            = 115_200,
    parameter TIMEOUT_CYCLES  = 1_000_000,   // 10 ms gap abandons a frame
    parameter DEBOUNCE_CYCLES = 1_000_000,   // 10 ms button debounce
    parameter HEARTBEAT_BIT   = 26           // about 0.67 s per toggle
) (
    input  wire       clk,
    input  wire       btn_c,
    input  wire       uart_rx,
    output wire       uart_tx,
    output reg  [7:0] led
);
    localparam CLKS_PER_BIT = CLK_HZ / BAUD;
    localparam [2:0] R_DUP = 3'd2, R_STL = 3'd3;

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

    // UART receive and framing.
    wire [7:0]   rx_data;
    wire         rx_valid, rx_err;
    wire [127:0] frame;
    wire         frame_valid, reset_req, parse_err;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst(rst), .rx(uart_rx),
        .data(rx_data), .valid(rx_valid), .frame_err(rx_err)
    );

    frame_parser #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) u_parser (
        .clk(clk), .rst(rst), .byte_valid(rx_valid), .byte_data(rx_data), .byte_err(rx_err),
        .frame_valid(frame_valid), .frame(frame), .reset_req(reset_req), .parse_err(parse_err)
    );

    wire session_clear = reset_req || btn_press;

    // Authentication, then both replay engines on the same authenticated result.
    // keep_hierarchy stops Vivado moving logic across these module boundaries,
    // so the per-module numbers in the utilization report are meaningful.
    wire        auth_done, mac_ok;
    wire [31:0] seq;
    (* keep_hierarchy = "yes" *)
    auth_stage u_auth (
        .clk(clk), .rst(rst), .frame_valid(frame_valid), .pkt(frame),
        .auth_done(auth_done), .mac_ok(mac_ok), .seq(seq)
    );

    wire strict_valid, strict_accept;
    (* keep_hierarchy = "yes" *)
    strict_counter u_strict (
        .clk(clk), .rst(rst), .clear(session_clear),
        .in_valid(auth_done), .mac_ok(mac_ok), .seq(seq),
        .out_valid(strict_valid), .accept(strict_accept)
    );

    wire       window_valid, window_accept;
    wire [2:0] window_reason;
    (* keep_hierarchy = "yes" *)
    sliding_window #(.W(W)) u_window (
        .clk(clk), .rst(rst), .clear(session_clear),
        .in_valid(auth_done), .mac_ok(mac_ok), .seq(seq),
        .out_valid(window_valid), .accept(window_accept), .reason(window_reason)
    );

    // Both engines answer on the same clock. Their state is independent.
    wire verdict_valid = window_valid;

    // Latency: clocks from frame_valid to the verdict.
    reg [15:0] lat_cnt;
    reg [15:0] verdict_count;
    reg        mac_ok_d;
    always @(posedge clk) begin
        if (rst) begin
            lat_cnt       <= 16'd0;
            verdict_count <= 16'd0;
        end else begin
            if (frame_valid)
                lat_cnt <= 16'd1;
            else if (lat_cnt != 16'hFFFF)
                lat_cnt <= lat_cnt + 16'd1;
            if (verdict_valid)
                verdict_count <= verdict_count + 16'd1;
        end
        if (auth_done)
            mac_ok_d <= mac_ok;
    end

    telemetry #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tel (
        .clk(clk), .rst(rst),
        .verdict_valid(verdict_valid), .seq(seq), .mac_ok(mac_ok_d),
        .strict_accept(strict_accept), .window_accept(window_accept),
        .window_reason(window_reason), .latency(lat_cnt),
        .count(verdict_count + 16'd1),
        .reset_event(session_clear), .error_event(parse_err),
        .tx(uart_tx)
    );

    // LEDs.
    reg [31:0] heartbeat = 32'd0;
    always @(posedge clk) begin
        heartbeat <= heartbeat + 32'd1;
        led[7]    <= heartbeat[HEARTBEAT_BIT];
        if (rst) begin
            led[6:0] <= 7'd0;
        end else begin
            if (frame_valid)
                led[0] <= ~led[0];
            if (session_clear) begin
                led[6:1] <= 6'd0;
            end else if (verdict_valid) begin
                led[1] <= mac_ok_d;
                led[2] <= ~mac_ok_d;
                led[3] <= strict_accept;
                led[4] <= window_accept;
                led[5] <= (window_reason == R_DUP);
                led[6] <= (window_reason == R_STL);
            end
        end
    end
endmodule
