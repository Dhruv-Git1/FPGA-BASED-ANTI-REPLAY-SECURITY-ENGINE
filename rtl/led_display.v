// LED status display. The datapath decides in 12 clocks, far too fast to see,
// so this module replays each event slowly enough for a person to follow.
// It only reads events. It never affects authentication or replay state.
//
//   boot (after reset)  one light sweeps back and forth twice
//   idle                LD7 heartbeat only
//   verdict             lights fill in stage by stage, then the result is held:
//                         LD0 frame received
//                         LD1 MAC ok           LD2 MAC failed (blinks)
//                         LD3 strict accepted
//                         LD4 window accepted  LD5 duplicate (blinks)  LD6 stale (blinks)
//                       LD7 keeps the heartbeat during verdict display
//   session clear       all eight LEDs flash twice
//   parse error         LD0 blinks quickly
//   host pass           LEDs fill one by one, then all stay on
//   host fail           all eight LEDs blink quickly
// Any new event replaces the current display.
module led_display #(
    parameter TICK_CYCLES = 12_500_000,  // one display step, 125 ms at 100 MHz
    parameter STAGE_TICKS = 2            // steps per verdict stage
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       verdict_valid,
    input  wire       mac_ok,
    input  wire       strict_accept,
    input  wire       window_accept,
    input  wire [2:0] window_reason,
    input  wire       session_clear,
    input  wire       parse_err,
    input  wire       host_pass,
    input  wire       host_fail,
    output reg  [7:0] led
);
    localparam [2:0] M_BOOT = 3'd0, M_IDLE = 3'd1, M_WALK = 3'd2, M_HOLD = 3'd3,
                     M_CLEAR = 3'd4, M_ERR = 3'd5, M_PASS = 3'd6, M_FAIL = 3'd7;
    localparam [2:0] R_DUP = 3'd2, R_STL = 3'd3;
    localparam BOOT_TICKS  = 28;  // two sweeps of 14 positions
    localparam CLEAR_TICKS = 4;
    localparam ERR_TICKS   = 6;
    localparam [5:0] STEP_MAX = 6'd63;

    reg [2:0]  mode;
    reg [5:0]  step;      // display steps since the current mode started
    reg [31:0] tick_cnt;
    reg [7:0]  beat;      // free-running step counter for blinking
    reg        v_mac, v_str, v_win;
    reg [2:0]  v_reason;

    wire tick  = (tick_cnt == TICK_CYCLES - 1);
    wire fast  = beat[0];  // 4 Hz blink
    wire heart = beat[3];  // 0.5 Hz heartbeat
    // A new event restarts the step timer, so its first step is full length.
    wire event_start = session_clear | verdict_valid | parse_err | host_pass | host_fail;

    always @(posedge clk) begin
        if (rst || tick || event_start)
            tick_cnt <= 32'd0;
        else
            tick_cnt <= tick_cnt + 32'd1;

        if (rst) begin
            mode <= M_BOOT;
            step <= 6'd0;
            beat <= 8'd0;
        end else begin
            if (tick)
                beat <= beat + 8'd1;
            if (session_clear) begin
                mode <= M_CLEAR;
                step <= 6'd0;
            end else if (verdict_valid) begin
                mode     <= M_WALK;
                step     <= 6'd0;
                v_mac    <= mac_ok;
                v_str    <= strict_accept;
                v_win    <= window_accept;
                v_reason <= window_reason;
            end else if (parse_err) begin
                mode <= M_ERR;
                step <= 6'd0;
            end else if (host_pass) begin
                mode <= M_PASS;
                step <= 6'd0;
            end else if (host_fail) begin
                mode <= M_FAIL;
                step <= 6'd0;
            end else if (tick) begin
                if (step != STEP_MAX)
                    step <= step + 6'd1;
                case (mode)
                    M_BOOT:  if (step == BOOT_TICKS - 1)      begin mode <= M_IDLE; step <= 6'd0; end
                    M_WALK:  if (step == 4 * STAGE_TICKS - 1) begin mode <= M_HOLD; step <= 6'd0; end
                    M_CLEAR: if (step == CLEAR_TICKS - 1)     begin mode <= M_IDLE; step <= 6'd0; end
                    M_ERR:   if (step == ERR_TICKS - 1)       begin mode <= M_IDLE; step <= 6'd0; end
                    default: ;
                endcase
            end
        end
    end

    // Verdict lights, LD0 to LD6, in the order the datapath produces them.
    wire [6:0] verdict_bits = {
        v_reason == R_STL,   // LD6
        v_reason == R_DUP,   // LD5
        v_win,               // LD4
        v_str,               // LD3
        ~v_mac,              // LD2
        v_mac,               // LD1
        1'b1                 // LD0
    };
    // Bits that mean "rejected" blink while the verdict is held.
    wire [6:0] blink_bits = 7'b1100100;

    wire [5:0] stage = step / STAGE_TICKS;
    reg  [6:0] stage_mask;
    always @(*) begin
        case (stage)
            6'd0:    stage_mask = 7'b0000001;  // received
            6'd1:    stage_mask = 7'b0000111;  // + authentication result
            6'd2:    stage_mask = 7'b0001111;  // + strict engine
            default: stage_mask = 7'b1111111;  // + sliding window
        endcase
    end

    // Boot sweep position: 0, 1, .. 7, then 6, 5, .. 1, twice.
    wire [5:0] sweep = (step >= 6'd14) ? step - 6'd14 : step;
    wire [5:0] back  = 6'd14 - sweep;
    wire [2:0] pos   = (sweep < 6'd8) ? sweep[2:0] : back[2:0];

    always @(posedge clk) begin
        case (mode)
            M_BOOT:  led <= 8'd1 << pos;
            M_IDLE:  led <= {heart, 7'd0};
            M_WALK:  led <= {heart, verdict_bits & stage_mask};
            M_HOLD:  led <= {heart, verdict_bits & ~(blink_bits & {7{~fast}})};
            M_CLEAR: led <= step[0] ? 8'h00 : 8'hFF;
            M_ERR:   led <= {heart, 6'd0, fast};
            M_PASS:  led <= (step < 6'd8) ? ((9'd2 << step[2:0]) - 9'd1) : 8'hFF;
            default: led <= fast ? 8'hFF : 8'h00;  // M_FAIL
        endcase
    end
endmodule
