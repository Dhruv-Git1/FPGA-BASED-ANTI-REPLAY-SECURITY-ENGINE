// ASCII telemetry over UART TX. One line per event (format in host/telemetry.py):
//   SEQ=00000004 MAC=1 STR=0 WIN=1 WR=NEW LAT=000D CNT=0005\r\n
//   RST\r\n
//   ERR\r\n
// Event fields are copied into a snapshot when the line starts. A line takes
// about 5 ms at 115200 baud, and an event that arrives while a line is still
// being sent is dropped. The host therefore waits for each line before sending
// the next frame. CNT lets the host notice a dropped verdict line.
module telemetry #(
    parameter CLKS_PER_BIT = 868
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        verdict_valid,
    input  wire [31:0] seq,
    input  wire        mac_ok,
    input  wire        strict_accept,
    input  wire        window_accept,
    input  wire [2:0]  window_reason,
    input  wire [15:0] latency,
    input  wire [15:0] count,
    input  wire        reset_event,
    input  wire        error_event,
    output wire        tx
);
    localparam [1:0] T_VERDICT = 2'd0, T_RST = 2'd1, T_ERR = 2'd2;
    localparam [1:0] S_IDLE = 2'd0, S_SEND = 2'd1, S_WAIT = 2'd2;
    localparam [5:0] VERDICT_LEN = 6'd57, SHORT_LEN = 6'd5;

    reg [1:0]  state;
    reg [1:0]  kind;
    reg [5:0]  idx;
    reg [31:0] s_seq;
    reg        s_mac, s_str, s_win;
    reg [2:0]  s_reason;
    reg [15:0] s_lat, s_cnt;
    reg        tx_start;
    reg [7:0]  ch;
    wire       tx_done;
    wire       tx_busy;

    function [7:0] hex;
        input [3:0] n;
        hex = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);  // '0'..'9', 'A'..'F'
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

    wire [23:0] rtext = reason_text(s_reason);

    // Character at position idx of the current line.
    always @(*) begin
        if (kind != T_VERDICT) begin
            case (idx)
                6'd0:    ch = (kind == T_RST) ? "R" : "E";
                6'd1:    ch = (kind == T_RST) ? "S" : "R";
                6'd2:    ch = (kind == T_RST) ? "T" : "R";
                6'd3:    ch = 8'h0D;
                default: ch = 8'h0A;
            endcase
        end else begin
            case (idx)
                6'd0:  ch = "S";  6'd1:  ch = "E";  6'd2:  ch = "Q";  6'd3:  ch = "=";
                6'd4:  ch = hex(s_seq[31:28]);  6'd5:  ch = hex(s_seq[27:24]);
                6'd6:  ch = hex(s_seq[23:20]);  6'd7:  ch = hex(s_seq[19:16]);
                6'd8:  ch = hex(s_seq[15:12]);  6'd9:  ch = hex(s_seq[11:8]);
                6'd10: ch = hex(s_seq[7:4]);    6'd11: ch = hex(s_seq[3:0]);
                6'd12: ch = " "; 6'd13: ch = "M"; 6'd14: ch = "A"; 6'd15: ch = "C"; 6'd16: ch = "=";
                6'd17: ch = s_mac ? "1" : "0";
                6'd18: ch = " "; 6'd19: ch = "S"; 6'd20: ch = "T"; 6'd21: ch = "R"; 6'd22: ch = "=";
                6'd23: ch = s_str ? "1" : "0";
                6'd24: ch = " "; 6'd25: ch = "W"; 6'd26: ch = "I"; 6'd27: ch = "N"; 6'd28: ch = "=";
                6'd29: ch = s_win ? "1" : "0";
                6'd30: ch = " "; 6'd31: ch = "W"; 6'd32: ch = "R"; 6'd33: ch = "=";
                6'd34: ch = rtext[23:16]; 6'd35: ch = rtext[15:8]; 6'd36: ch = rtext[7:0];
                6'd37: ch = " "; 6'd38: ch = "L"; 6'd39: ch = "A"; 6'd40: ch = "T"; 6'd41: ch = "=";
                6'd42: ch = hex(s_lat[15:12]); 6'd43: ch = hex(s_lat[11:8]);
                6'd44: ch = hex(s_lat[7:4]);   6'd45: ch = hex(s_lat[3:0]);
                6'd46: ch = " "; 6'd47: ch = "C"; 6'd48: ch = "N"; 6'd49: ch = "T"; 6'd50: ch = "=";
                6'd51: ch = hex(s_cnt[15:12]); 6'd52: ch = hex(s_cnt[11:8]);
                6'd53: ch = hex(s_cnt[7:4]);   6'd54: ch = hex(s_cnt[3:0]);
                6'd55: ch = 8'h0D;
                default: ch = 8'h0A;
            endcase
        end
    end

    wire [5:0] line_len = (kind == T_VERDICT) ? VERDICT_LEN : SHORT_LEN;

    always @(posedge clk) begin
        tx_start <= 1'b0;
        if (rst) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: begin
                    idx <= 6'd0;
                    if (verdict_valid) begin
                        kind     <= T_VERDICT;
                        s_seq    <= seq;
                        s_mac    <= mac_ok;
                        s_str    <= strict_accept;
                        s_win    <= window_accept;
                        s_reason <= window_reason;
                        s_lat    <= latency;
                        s_cnt    <= count;
                        state    <= S_SEND;
                    end else if (reset_event) begin
                        kind  <= T_RST;
                        state <= S_SEND;
                    end else if (error_event) begin
                        kind  <= T_ERR;
                        state <= S_SEND;
                    end
                end
                S_SEND: begin
                    tx_start <= 1'b1;
                    state    <= S_WAIT;
                end
                default: if (tx_done) begin
                    if (idx == line_len - 6'd1) begin
                        state <= S_IDLE;
                    end else begin
                        idx   <= idx + 6'd1;
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
