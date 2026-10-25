// UART transmitter, 8 data bits, no parity, 1 stop bit, least-significant bit first.
// Pulse `start` while not busy. `done` pulses once the stop bit has been sent.
module uart_tx #(
    parameter CLKS_PER_BIT = 868
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       start,
    input  wire [7:0] data,
    output reg        tx = 1'b1,
    output reg        busy,
    output reg        done
);
    reg [9:0]  shift;  // stop bit, 8 data bits, start bit (sent from bit 0 up)
    reg [3:0]  bits_left;
    reg [15:0] cnt;

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            tx   <= 1'b1;
            busy <= 1'b0;
        end else if (!busy) begin
            if (start) begin
                shift     <= {1'b1, data, 1'b0};
                bits_left <= 4'd10;
                cnt       <= 16'd0;
                busy      <= 1'b1;
            end
        end else if (cnt == 16'd0) begin
            if (bits_left == 4'd0) begin
                busy <= 1'b0;
                done <= 1'b1;
            end else begin
                tx        <= shift[0];
                shift     <= {1'b1, shift[9:1]};
                bits_left <= bits_left - 4'd1;
                cnt       <= CLKS_PER_BIT - 1;
            end
        end else begin
            cnt <= cnt - 16'd1;
        end
    end
endmodule
