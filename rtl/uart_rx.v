// UART receiver, 8 data bits, no parity, 1 stop bit, least-significant bit first.
//
// The input pin passes through two flip-flops first, because it is not
// synchronized to our clock. A byte starts on a falling edge. Each bit is
// sampled in the middle of its bit period. A low stop bit raises frame_err
// instead of valid. Because a new byte needs a falling edge, the receiver
// waits for the line to return high after an error before it listens again.
module uart_rx #(
    parameter CLKS_PER_BIT = 868  // 100 MHz / 115200 baud
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid,
    output reg        frame_err
);
    localparam [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

    reg        rx_s1 = 1'b1, rx_s2 = 1'b1, rx_prev = 1'b1;
    reg [1:0]  state;
    reg [15:0] cnt;
    reg [2:0]  bit_idx;

    always @(posedge clk) begin
        rx_s1   <= rx;
        rx_s2   <= rx_s1;
        rx_prev <= rx_s2;
        valid     <= 1'b0;
        frame_err <= 1'b0;
        if (rst) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: if (rx_prev && !rx_s2) begin
                    state <= S_START;
                    cnt   <= 16'd0;
                end
                S_START: if (cnt == CLKS_PER_BIT/2 - 1) begin
                    // Middle of the start bit. A high line here was a glitch.
                    state   <= rx_s2 ? S_IDLE : S_DATA;
                    cnt     <= 16'd0;
                    bit_idx <= 3'd0;
                end else begin
                    cnt <= cnt + 16'd1;
                end
                S_DATA: if (cnt == CLKS_PER_BIT - 1) begin
                    cnt           <= 16'd0;
                    data[bit_idx] <= rx_s2;
                    bit_idx       <= bit_idx + 3'd1;
                    if (bit_idx == 3'd7)
                        state <= S_STOP;
                end else begin
                    cnt <= cnt + 16'd1;
                end
                default: if (cnt == CLKS_PER_BIT - 1) begin
                    valid     <= rx_s2;
                    frame_err <= !rx_s2;
                    state     <= S_IDLE;
                end else begin
                    cnt <= cnt + 16'd1;
                end
            endcase
        end
    end
endmodule
