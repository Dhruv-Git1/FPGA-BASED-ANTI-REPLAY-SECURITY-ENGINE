// Decision & Control (RCPROJECT.pdf, section 4.5 and the architecture figure).
//
// Both replay engines always run and report. This block picks the one chosen by
// switch SW0 (0 = strict counter "SC", 1 = sliding window "SW") and produces a
// single final verdict:
//   final_accept = tag valid AND the selected engine accepts
// Only a final accept executes the packet's command (payload):
//   0001 OPEN  opens the door, 0002 CLOSE closes it, anything else changes nothing.
// It also keeps accepted and rejected counts for each engine in the current
// session, as four-digit decimal (BCD) counters, cleared by session_clear.
// Outputs are registered and valid with decision_valid, one clock after the engines.
module decision_control (
    input  wire        clk,
    input  wire        rst,
    input  wire        policy_sw,       // already synchronized: 0 = SC, 1 = SW
    input  wire        session_clear,
    input  wire        verdict_valid,   // engines' out_valid
    input  wire        mac_ok,
    input  wire        strict_accept,
    input  wire        window_accept,
    input  wire [15:0] cmd,
    output reg         decision_valid,
    output reg         policy,          // policy that produced this decision
    output reg         final_accept,
    output reg         door_open,
    output reg  [15:0] sc_acc,
    output reg  [15:0] sc_rej,
    output reg  [15:0] sw_acc,
    output reg  [15:0] sw_rej
);
    localparam [15:0] CMD_OPEN = 16'h0001, CMD_CLOSE = 16'h0002;

    function [15:0] bcd_inc;  // add 1 to four BCD digits, 9999 wraps to 0000
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

    wire accept = mac_ok && (policy_sw ? window_accept : strict_accept);

    always @(posedge clk) begin
        decision_valid <= 1'b0;
        if (rst) begin
            door_open <= 1'b0;
            sc_acc <= 16'd0; sc_rej <= 16'd0; sw_acc <= 16'd0; sw_rej <= 16'd0;
        end else if (session_clear) begin
            sc_acc <= 16'd0; sc_rej <= 16'd0; sw_acc <= 16'd0; sw_rej <= 16'd0;
        end else if (verdict_valid) begin
            decision_valid <= 1'b1;
            policy         <= policy_sw;
            final_accept   <= accept;
            if (accept && cmd == CMD_OPEN)  door_open <= 1'b1;
            if (accept && cmd == CMD_CLOSE) door_open <= 1'b0;
            if (strict_accept) sc_acc <= bcd_inc(sc_acc); else sc_rej <= bcd_inc(sc_rej);
            if (window_accept) sw_acc <= bcd_inc(sw_acc); else sw_rej <= bcd_inc(sw_rej);
        end
    end
endmodule
