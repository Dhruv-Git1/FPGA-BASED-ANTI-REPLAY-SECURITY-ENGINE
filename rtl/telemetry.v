// ASCII telemetry over UART TX. One line per event (format in host/telemetry.py):
//   SEQ=00000004 CMD=0001 MAC=1 STR=0 WIN=1 WR=NEW POL=SW RES=ACC DOOR=O LAT=000D CNT=0005 SC=0003/0001 SW=0004/0000
//   RST EPOCH=0000000A POL=SC      signed reset accepted
//   RST DENIED                     reset with a bad tag or an epoch that is not higher
//   RST BUTTON                     BTNC pressed
//   ERR                            frame cut off or broken byte
//   LOST EVENTS                    the queue was full and at least one event was dropped
//
// A line takes up to 10 ms at 115200 baud, while frames can arrive every 1.6 ms.
// Events therefore go into a 16-entry queue and are sent in order, so a burst of
// frames, or a reset arriving while a line is being sent, is never lost from the
// log. Verdicts and signed-reset results come from the authentication path, at
// most one per frame. Button and parser-error events are rarer and wait in a
// one-bit flag until the queue's write port is free.
module telemetry #(
    parameter CLKS_PER_BIT = 868
) (
    input  wire        clk,
    input  wire        rst,
    // verdict, from decision_control
    input  wire        verdict_valid,
    input  wire [31:0] seq,
    input  wire [15:0] cmd,
    input  wire        mac_ok,
    input  wire        strict_accept,
    input  wire        window_accept,
    input  wire [2:0]  window_reason,
    input  wire        policy,
    input  wire        final_accept,
    input  wire        door_open,
    input  wire [15:0] latency,
    input  wire [15:0] count,
    input  wire [15:0] sc_acc,
    input  wire [15:0] sc_rej,
    input  wire [15:0] sw_acc,
    input  wire [15:0] sw_rej,
    // other events
    input  wire        reset_ok,        // signed reset accepted; epoch is on `seq`
    input  wire        reset_denied,
    input  wire        reset_button,
    input  wire        error_event,
    output wire        tx
);
    localparam [2:0] K_VERDICT = 3'd0, K_RST_OK = 3'd1, K_RST_NO = 3'd2,
                     K_RST_BTN = 3'd3, K_ERR = 3'd4, K_LOST = 3'd5;
    localparam EW = 156;  // queue entry width, see pack below
    localparam LINE_CHARS = 112;

    // ---- event queue --------------------------------------------------------
    reg [EW-1:0] fifo [0:15];
    reg [4:0]    wr_ptr, rd_ptr;
    wire         empty = (wr_ptr == rd_ptr);
    wire         full  = (wr_ptr[3:0] == rd_ptr[3:0]) && (wr_ptr[4] != rd_ptr[4]);
    reg          pend_btn, pend_err, pend_lost;
    reg          rd_en;

    function [EW-1:0] pack;
        input [2:0] kind;
        pack = {kind, seq, cmd, mac_ok, strict_accept, window_accept, policy, final_accept,
                door_open, window_reason, latency, count, sc_acc, sc_rej, sw_acc, sw_rej};
    endfunction

    reg          wr_en;
    reg [EW-1:0] wr_data;
    always @(*) begin
        wr_en   = 1'b1;
        wr_data = pack(K_VERDICT);
        if (verdict_valid)     wr_data = pack(K_VERDICT);
        else if (reset_ok)     wr_data = pack(K_RST_OK);
        else if (reset_denied) wr_data = pack(K_RST_NO);
        else if (pend_btn)     wr_data = pack(K_RST_BTN);
        else if (pend_err)     wr_data = pack(K_ERR);
        else if (pend_lost)    wr_data = pack(K_LOST);
        else                   wr_en   = 1'b0;
    end
    wire primary = verdict_valid | reset_ok | reset_denied;

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr    <= 5'd0;
            rd_ptr    <= 5'd0;
            pend_btn  <= 1'b0;
            pend_err  <= 1'b0;
            pend_lost <= 1'b0;
        end else begin
            if (wr_en && !full) begin
                fifo[wr_ptr[3:0]] <= wr_data;
                wr_ptr <= wr_ptr + 5'd1;
            end
            // Flags: set by their event, cleared once their entry is written.
            if (reset_button) pend_btn <= 1'b1;
            else if (!primary && pend_btn && !full) pend_btn <= 1'b0;
            if (error_event) pend_err <= 1'b1;
            else if (!primary && !pend_btn && pend_err && !full) pend_err <= 1'b0;
            // Only authentication-path events are dropped when full. Flags just wait.
            if (primary && full) pend_lost <= 1'b1;
            else if (!primary && !pend_btn && !pend_err && pend_lost && !full) pend_lost <= 1'b0;
            if (rd_en)
                rd_ptr <= rd_ptr + 5'd1;
        end
    end

    // ---- line formatting ----------------------------------------------------
    reg [EW-1:0] cur;
    wire [2:0]  c_kind   = cur[155:153];
    wire [31:0] c_seq    = cur[152:121];
    wire [15:0] c_cmd    = cur[120:105];
    wire        c_mac    = cur[104];
    wire        c_str    = cur[103];
    wire        c_win    = cur[102];
    wire        c_pol    = cur[101];
    wire        c_fin    = cur[100];
    wire        c_door   = cur[99];
    wire [2:0]  c_reason = cur[98:96];
    wire [15:0] c_lat    = cur[95:80];
    wire [15:0] c_cnt    = cur[79:64];
    wire [15:0] c_sca    = cur[63:48];
    wire [15:0] c_scr    = cur[47:32];
    wire [15:0] c_swa    = cur[31:16];
    wire [15:0] c_swr    = cur[15:0];

    function [7:0] hex;
        input [3:0] n;
        hex = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);  // '0'..'9', 'A'..'F'
    endfunction
    function [31:0] hex4;
        input [15:0] v;
        hex4 = {hex(v[15:12]), hex(v[11:8]), hex(v[7:4]), hex(v[3:0])};
    endfunction
    function [63:0] hex8;
        input [31:0] v;
        hex8 = {hex4(v[31:16]), hex4(v[15:0])};
    endfunction
    function [31:0] bcd4;  // four BCD digits as text
        input [15:0] v;
        bcd4 = {8'h30 + v[15:12], 8'h30 + v[11:8], 8'h30 + v[7:4], 8'h30 + v[3:0]};
    endfunction
    function [23:0] reason_text;
        input [2:0] r;
        case (r)
            3'd0:    reason_text = "NEW";
            3'd1:    reason_text = "INW";
            3'd2:    reason_text = "DUP";
            3'd3:    reason_text = "STL";
            default: reason_text = "AUT";
        endcase
    endfunction

    wire [15:0] pol_text = c_pol ? "SW" : "SC";

    // Each line is left-aligned in a LINE_CHARS-character vector.
    reg [8*LINE_CHARS-1:0] line;
    reg [6:0]              line_len;
    always @(*) begin
        case (c_kind)
            K_VERDICT: begin
                line = {"SEQ=", hex8(c_seq), " CMD=", hex4(c_cmd),
                        " MAC=", c_mac ? "1" : "0", " STR=", c_str ? "1" : "0",
                        " WIN=", c_win ? "1" : "0", " WR=", reason_text(c_reason),
                        " POL=", pol_text, " RES=", c_fin ? "ACC" : "REJ",
                        " DOOR=", c_door ? "O" : "C", " LAT=", hex4(c_lat), " CNT=", hex4(c_cnt),
                        " SC=", bcd4(c_sca), "/", bcd4(c_scr), " SW=", bcd4(c_swa), "/", bcd4(c_swr)};
                line_len = 7'd112;
            end
            K_RST_OK: begin
                line = {"RST EPOCH=", hex8(c_seq), " POL=", pol_text, {(LINE_CHARS - 25){8'h20}}};
                line_len = 7'd25;
            end
            K_RST_NO: begin
                line = {"RST DENIED", {(LINE_CHARS - 10){8'h20}}};
                line_len = 7'd10;
            end
            K_RST_BTN: begin
                line = {"RST BUTTON", {(LINE_CHARS - 10){8'h20}}};
                line_len = 7'd10;
            end
            K_ERR: begin
                line = {"ERR", {(LINE_CHARS - 3){8'h20}}};
                line_len = 7'd3;
            end
            default: begin
                line = {"LOST EVENTS", {(LINE_CHARS - 11){8'h20}}};
                line_len = 7'd11;
            end
        endcase
    end

    // ---- sender -------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_SEND = 2'd1, S_WAIT = 2'd2;
    reg [1:0] state;
    reg [6:0] idx;
    reg       tx_start;
    reg [7:0] ch;
    wire      tx_done, tx_busy;

    always @(*) begin
        if (idx < line_len)       ch = line[8 * (LINE_CHARS - 1 - idx) +: 8];
        else if (idx == line_len) ch = 8'h0D;
        else                      ch = 8'h0A;
    end

    always @(posedge clk) begin
        tx_start <= 1'b0;
        rd_en    <= 1'b0;
        if (rst) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: if (!empty && !rd_en) begin
                    cur   <= fifo[rd_ptr[3:0]];
                    rd_en <= 1'b1;
                    idx   <= 7'd0;
                    state <= S_SEND;
                end
                S_SEND: begin
                    tx_start <= 1'b1;
                    state    <= S_WAIT;
                end
                default: if (tx_done) begin
                    if (idx == line_len + 7'd1) begin
                        state <= S_IDLE;
                    end else begin
                        idx   <= idx + 7'd1;
                        state <= S_SEND;
                    end
                end
            endcase
        end
    end

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst(rst), .start(tx_start), .data(ch),
        .tx(tx), .busy(tx_busy), .done(tx_done)
    );
endmodule
