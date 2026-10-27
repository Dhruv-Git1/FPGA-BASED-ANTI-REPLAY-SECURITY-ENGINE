// Text shown on the ZedBoard OLED: 4 lines of 16 characters.
//
// Like led_display.v, this module only reads events and replays them slowly
// enough to read. A verdict reveals one line per stage, in datapath order:
//   RX  SEQ=00000004     frame received
//   AUTH OK   12 CLK     tag check result and clocks from frame to verdict
//   STRICT: REJECT       strict counter decision
//   WINDOW: OK NEW       sliding window decision and reason
// After a failed tag check both engines show UNCHANGED, because their state
// is not touched. Boot, idle, session reset, frame error and the host's
// PASS / FAIL result each have their own screen.
//
// oled_ssd1306.v asks for the character at (row, col). The answer is combinational.
module oled_status #(
    parameter W           = 64,
    parameter TICK_CYCLES = 12_500_000,  // one display step, 125 ms at 100 MHz
    parameter STAGE_TICKS = 3            // steps per revealed line
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        verdict_valid,
    input  wire        mac_ok,
    input  wire        strict_accept,
    input  wire        window_accept,
    input  wire [2:0]  window_reason,
    input  wire [31:0] seq,
    input  wire [15:0] latency,
    input  wire        session_clear,
    input  wire        parse_err,
    input  wire        host_pass,
    input  wire        host_fail,
    input  wire [1:0]  row,
    input  wire [3:0]  col,
    output wire [6:0]  ch
);
    localparam [2:0] M_BOOT = 3'd0, M_IDLE = 3'd1, M_WALK = 3'd2, M_HOLD = 3'd3,
                     M_CLEAR = 3'd4, M_ERR = 3'd5, M_PASS = 3'd6, M_FAIL = 3'd7;
    localparam [2:0] R_NEW = 3'd0, R_INW = 3'd1, R_DUP = 3'd2, R_STL = 3'd3;
    localparam BOOT_TICKS = 16, NOTE_TICKS = 16;  // 2 s each
    localparam [5:0] STEP_MAX = 6'd63;

    // Window size as three right-aligned characters, fixed at build time.
    localparam [7:0] W_H = (W >= 100) ? 8'h30 + (W / 100) % 10 : " ";
    localparam [7:0] W_T = (W >= 10)  ? 8'h30 + (W / 10) % 10  : " ";
    localparam [7:0] W_O = 8'h30 + W % 10;
    localparam [23:0] W_TXT = {W_H, W_T, W_O};

    reg [2:0]  mode;
    reg [5:0]  step;
    reg [31:0] tick_cnt;
    reg        v_mac, v_str, v_win;
    reg [2:0]  v_reason;
    reg [31:0] v_seq;
    reg [7:0]  v_lat_t, v_lat_o;   // latency as two decimal digits
    reg [15:0] pkt_bcd;            // verdicts since power-on, four BCD digits

    wire tick = (tick_cnt == TICK_CYCLES - 1);
    wire event_start = session_clear | verdict_valid | parse_err | host_pass | host_fail;
    wire [15:0] lat_sat = (latency > 16'd99) ? 16'd99 : latency;

    function [7:0] hex;
        input [3:0] n;
        hex = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);
    endfunction

    function [15:0] bcd_inc;
        input [15:0] b;
        reg [4:0] d;
        integer i;
        reg carry;
        begin
            carry = 1'b1;
            for (i = 0; i < 4; i = i + 1) begin
                d = b[4*i +: 4] + carry;
                carry = (d == 5'd10);
                bcd_inc[4*i +: 4] = carry ? 4'd0 : d[3:0];
            end
        end
    endfunction

    always @(posedge clk) begin
        if (rst || tick || event_start)
            tick_cnt <= 32'd0;
        else
            tick_cnt <= tick_cnt + 32'd1;

        if (rst) begin
            mode    <= M_BOOT;
            step    <= 6'd0;
            pkt_bcd <= 16'd0;
        end else begin
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
                v_seq    <= seq;
                v_lat_t  <= 8'h30 + lat_sat / 10;
                v_lat_o  <= 8'h30 + lat_sat % 10;
                pkt_bcd  <= bcd_inc(pkt_bcd);
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
                    M_CLEAR,
                    M_ERR:   if (step == NOTE_TICKS - 1)      begin mode <= M_IDLE; step <= 6'd0; end
                    default: ;
                endcase
            end
        end
    end

    wire [63:0] seq_hex = {hex(v_seq[31:28]), hex(v_seq[27:24]), hex(v_seq[23:20]), hex(v_seq[19:16]),
                           hex(v_seq[15:12]), hex(v_seq[11:8]),  hex(v_seq[7:4]),   hex(v_seq[3:0])};
    wire [31:0] pkt_txt = {8'h30 + pkt_bcd[15:12], 8'h30 + pkt_bcd[11:8],
                           8'h30 + pkt_bcd[7:4],   8'h30 + pkt_bcd[3:0]};

    // "LOADING " then a bar of '#' and '.' that fills during boot.
    reg [63:0] bar;
    integer k;
    always @(*) begin
        for (k = 0; k < 8; k = k + 1)
            bar[8*(7-k) +: 8] = (step >= 2 * k) ? "#" : ".";
    end

    wire [5:0] stage = step / STAGE_TICKS;

    reg [127:0] verdict_line;
    always @(*) begin
        case (row)
            2'd0: verdict_line = {"RX  SEQ=", seq_hex};
            2'd1: verdict_line = v_mac ? {"AUTH OK   ", v_lat_t, v_lat_o, " CLK"}
                                       : "AUTH FAILED!    ";
            2'd2: verdict_line = !v_mac ? "STRICT UNCHANGED"
                               : v_str  ? "STRICT: ACCEPT  " : "STRICT: REJECT  ";
            default: begin
                if (!v_mac)                 verdict_line = "WINDOW UNCHANGED";
                else if (v_reason == R_NEW) verdict_line = "WINDOW: OK NEW  ";
                else if (v_reason == R_INW) verdict_line = "WINDOW: OK LATE ";
                else if (v_reason == R_DUP) verdict_line = "WINDOW: REPLAY! ";
                else                        verdict_line = "WINDOW: TOO OLD ";
            end
        endcase
    end

    reg [127:0] line;
    always @(*) begin
        case (mode)
            M_BOOT: case (row)
                2'd0:    line = "ANTI-REPLAY FPGA";
                2'd1:    line = "MAC: SIPHASH-2-4";
                2'd2:    line = {"LOADING ", bar};
                default: line = {"WINDOW SIZE ", W_TXT, " "};
            endcase
            M_IDLE: case (row)
                2'd0:    line = "ANTI-REPLAY FPGA";
                2'd1:    line = "STATUS: READY   ";
                2'd2:    line = {"WINDOW SIZE ", W_TXT, " "};
                default: line = {"PACKETS   ", pkt_txt, "  "};
            endcase
            M_WALK:  line = ({4'd0, row} <= stage) ? verdict_line : "                ";
            M_HOLD:  line = verdict_line;
            M_CLEAR: case (row)
                2'd0:    line = "SESSION RESET   ";
                2'd1:    line = "STRICT EXPECTS 1";
                2'd2:    line = "WINDOW CLEARED  ";
                default: line = {"PACKETS   ", pkt_txt, "  "};
            endcase
            M_ERR: case (row)
                2'd0:    line = "FRAME ERROR     ";
                2'd1:    line = "BAD BYTE OR GAP ";
                2'd2:    line = "FRAME DISCARDED ";
                default: line = "WAITING FOR A55A";
            endcase
            M_PASS: case (row)
                2'd1:    line = "ALL TESTS PASSED";
                2'd2:    line = {"PACKETS   ", pkt_txt, "  "};
                default: line = "****************";
            endcase
            default: case (row)  // M_FAIL
                2'd1:    line = "TEST RUN FAILED ";
                2'd2:    line = "SEE PC LOG      ";
                default: line = "!!!!!!!!!!!!!!!!";
            endcase
        endcase
    end

    assign ch = line[8 * (15 - col) +: 7];
endmodule
