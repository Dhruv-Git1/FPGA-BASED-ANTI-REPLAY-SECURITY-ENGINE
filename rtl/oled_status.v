// Text shown on the ZedBoard OLED: 4 lines of 16 characters.
//
// Like led_display.v, this module only reads events and replays them slowly
// enough to read. A verdict reveals one line per stage, in datapath order, in
// the layout of the RCPROJECT.pdf OLED figure:
//   CMD: OPEN   0004     command (payload) and low 16 bits of the sequence number
//   AUTH: PASS           tag check
//   POLICY: SC S+ W-     selected policy, then each engine's own answer
//   RESULT: ACCEPT       final verdict, or RESULT: REJ AUTH / SEQ / DUP / OLD
// After 3 s the summary screen returns: policy, door state, and accepted (+) and
// rejected (-) counts per engine. Boot, signed and button resets, denied resets,
// frame errors and the host's PASS / FAIL each have their own screen.
//
// oled_ssd1306.v asks for the character at (row, col). The answer is combinational.
module oled_status #(
    parameter W           = 64,
    parameter TICK_CYCLES = 12_500_000,  // one display step, 125 ms at 100 MHz
    parameter STAGE_TICKS = 3            // steps per revealed line
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        verdict_valid,    // decision_valid
    input  wire        mac_ok,
    input  wire        strict_accept,
    input  wire        window_accept,
    input  wire [2:0]  window_reason,
    input  wire        policy_used,
    input  wire        final_accept,
    input  wire [15:0] cmd,
    input  wire [31:0] seq,              // sequence number, or epoch for a reset
    input  wire        door_open,
    input  wire        policy_live,      // current switch position, for the summary
    input  wire [15:0] sc_acc,
    input  wire [15:0] sc_rej,
    input  wire [15:0] sw_acc,
    input  wire [15:0] sw_rej,
    input  wire        reset_ok,
    input  wire        reset_button,
    input  wire        reset_denied,
    input  wire        parse_err,
    input  wire        host_pass,
    input  wire        host_fail,
    input  wire [1:0]  row,
    input  wire [3:0]  col,
    output wire [6:0]  ch
);
    localparam [3:0] M_BOOT = 4'd0, M_SUM = 4'd1, M_WALK = 4'd2, M_HOLD = 4'd3,
                     M_RST_OK = 4'd4, M_RST_BTN = 4'd5, M_RST_NO = 4'd6,
                     M_ERR = 4'd7, M_PASS = 4'd8, M_FAIL = 4'd9;
    localparam [2:0] R_DUP = 3'd2, R_STL = 3'd3;
    localparam BOOT_TICKS = 16, NOTE_TICKS = 16, HOLD_TICKS = 24;  // 2 s, 2 s, 3 s
    localparam [5:0] STEP_MAX = 6'd63;

    // Window size as three right-aligned characters, fixed at build time.
    localparam [7:0] W_H = (W >= 100) ? 8'h30 + (W / 100) % 10 : " ";
    localparam [7:0] W_T = (W >= 10)  ? 8'h30 + (W / 10) % 10  : " ";
    localparam [7:0] W_O = 8'h30 + W % 10;
    localparam [23:0] W_TXT = {W_H, W_T, W_O};

    reg [3:0]  mode;
    reg [5:0]  step;
    reg [31:0] tick_cnt;
    reg        v_mac, v_str, v_win, v_pol, v_fin;
    reg [2:0]  v_reason;
    reg [15:0] v_cmd;
    reg [31:0] v_seq;
    reg [15:0] pkt_bcd;  // verdicts since power-on, four BCD digits

    wire tick = (tick_cnt == TICK_CYCLES - 1);
    wire event_start = verdict_valid | reset_ok | reset_button | reset_denied
                     | parse_err | host_pass | host_fail;

    function [7:0] hex;
        input [3:0] n;
        hex = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);
    endfunction
    function [31:0] bcd4;
        input [15:0] v;
        bcd4 = {8'h30 + v[15:12], 8'h30 + v[11:8], 8'h30 + v[7:4], 8'h30 + v[3:0]};
    endfunction
    function [15:0] bcd_inc;
        input [15:0] b;
        reg [4:0] d;
        reg       carry;
        integer   i;
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
        end else if (event_start) begin
            step <= 6'd0;
            if (verdict_valid) begin
                mode     <= M_WALK;
                v_mac    <= mac_ok;
                v_str    <= strict_accept;
                v_win    <= window_accept;
                v_reason <= window_reason;
                v_pol    <= policy_used;
                v_fin    <= final_accept;
                v_cmd    <= cmd;
                v_seq    <= seq;
                pkt_bcd  <= bcd_inc(pkt_bcd);
            end else if (reset_ok) begin
                mode  <= M_RST_OK;
                v_seq <= seq;
            end else if (reset_button) mode <= M_RST_BTN;
            else if (reset_denied)     mode <= M_RST_NO;
            else if (parse_err)        mode <= M_ERR;
            else if (host_pass)        mode <= M_PASS;
            else                       mode <= M_FAIL;
        end else if (tick) begin
            if (step != STEP_MAX)
                step <= step + 6'd1;
            case (mode)
                M_BOOT:  if (step == BOOT_TICKS - 1)      begin mode <= M_SUM; step <= 6'd0; end
                M_WALK:  if (step == 4 * STAGE_TICKS - 1) begin mode <= M_HOLD; step <= 6'd0; end
                M_HOLD:  if (step == HOLD_TICKS - 1)      begin mode <= M_SUM; step <= 6'd0; end
                M_RST_OK, M_RST_BTN, M_RST_NO, M_ERR:
                         if (step == NOTE_TICKS - 1)      begin mode <= M_SUM; step <= 6'd0; end
                default: ;
            endcase
        end
    end

    wire [31:0] pkt_txt = bcd4(pkt_bcd);
    wire [63:0] seq_hex8 = {hex(v_seq[31:28]), hex(v_seq[27:24]), hex(v_seq[23:20]), hex(v_seq[19:16]),
                            hex(v_seq[15:12]), hex(v_seq[11:8]),  hex(v_seq[7:4]),   hex(v_seq[3:0])};
    wire [31:0] seq_hex4 = seq_hex8[31:0];

    reg [47:0] cmd_name;
    always @(*) begin
        case (v_cmd)
            16'h0001: cmd_name = "OPEN  ";
            16'h0002: cmd_name = "CLOSE ";
            16'h0003: cmd_name = "STATUS";
            default:  cmd_name = "DATA  ";
        endcase
    end

    // Why the final verdict rejected, under the selected policy.
    reg [31:0] why;
    always @(*) begin
        if (!v_mac)                  why = "AUTH";
        else if (!v_pol)             why = "SEQ ";  // strict counter: not the expected number
        else if (v_reason == R_DUP)  why = "DUP ";
        else if (v_reason == R_STL)  why = "OLD ";
        else                         why = "????";
    end

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
            2'd0:    verdict_line = {"CMD: ", cmd_name, " ", seq_hex4};
            2'd1:    verdict_line = v_mac ? "AUTH: PASS      " : "AUTH: FAIL      ";
            2'd2:    verdict_line = {"POLICY: ", v_pol ? "SW" : "SC",
                                     " S", v_str ? "+" : "-", " W", v_win ? "+" : "-"};
            default: verdict_line = v_fin ? "RESULT: ACCEPT  " : {"RESULT: REJ ", why};
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
            M_SUM: case (row)
                2'd0:    line = {"POLICY ", policy_live ? "SW" : "SC", "  W=", W_TXT};
                2'd1:    line = {"DOOR ", door_open ? "OPEN  " : "CLOSED", "     "};
                2'd2:    line = {"SC +", bcd4(sc_acc), " -", bcd4(sc_rej), "  "};
                default: line = {"SW +", bcd4(sw_acc), " -", bcd4(sw_rej), "  "};
            endcase
            M_WALK:  line = ({4'd0, row} <= stage) ? verdict_line : "                ";
            M_HOLD:  line = verdict_line;
            M_RST_OK: case (row)
                2'd0:    line = "SESSION RESET   ";
                2'd1:    line = {"EPOCH ", seq_hex8, "  "};
                2'd2:    line = "SIGNED TAG OK   ";
                default: line = "COUNTERS CLEARED";
            endcase
            M_RST_BTN: case (row)
                2'd0:    line = "SESSION RESET   ";
                2'd1:    line = "BY BUTTON BTNC  ";
                2'd2:    line = "                ";
                default: line = "COUNTERS CLEARED";
            endcase
            M_RST_NO: case (row)
                2'd0:    line = "RESET DENIED!   ";
                2'd1:    line = "BAD TAG OR OLD  ";
                2'd2:    line = "STATE UNCHANGED ";
                default: line = "POSSIBLE ATTACK ";
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
