// Frame parser: turns the UART byte stream into 16-byte packets.
//
//   A5 5A + 16 bytes  -> frame_valid pulse, frame_is_reset = 0 (data packet)
//   A5 C3 + 16 bytes  -> frame_valid pulse, frame_is_reset = 1 (signed reset request)
//   A5 E1 / A5 E0     -> host_pass / host_fail pulse (display only, no state change)
// The parser never acts on a reset itself. auth_stage checks its tag first.
//
// While a frame body is being collected, a UART framing error or a gap longer
// than TIMEOUT_CYCLES abandons the frame, pulses parse_err and goes back to
// searching for A5. Outside a frame body these events are ignored silently.
module frame_parser #(
    parameter TIMEOUT_CYCLES = 1_000_000  // 10 ms at 100 MHz
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         byte_valid,
    input  wire [7:0]   byte_data,
    input  wire         byte_err,
    output reg          frame_valid,
    output reg  [127:0] frame,
    output reg          frame_is_reset,
    output reg          host_pass,
    output reg          host_fail,
    output reg          parse_err
);
    localparam [1:0] S_SYNC0 = 2'd0, S_SYNC1 = 2'd1, S_DATA = 2'd2;

    reg [1:0]  state;
    reg [3:0]  count;
    reg [31:0] idle_timer;

    always @(posedge clk) begin
        frame_valid <= 1'b0;
        host_pass   <= 1'b0;
        host_fail   <= 1'b0;
        parse_err   <= 1'b0;
        if (rst) begin
            state      <= S_SYNC0;
            idle_timer <= 32'd0;
        end else if (byte_err) begin
            parse_err <= (state == S_DATA);
            state     <= S_SYNC0;
        end else if (byte_valid) begin
            idle_timer <= 32'd0;
            case (state)
                S_SYNC0: if (byte_data == 8'hA5) state <= S_SYNC1;
                S_SYNC1: begin
                    if (byte_data == 8'h5A || byte_data == 8'hC3) begin
                        state          <= S_DATA;
                        count          <= 4'd0;
                        frame_is_reset <= (byte_data == 8'hC3);
                    end else if (byte_data == 8'hE1) begin
                        host_pass <= 1'b1;
                        state     <= S_SYNC0;
                    end else if (byte_data == 8'hE0) begin
                        host_fail <= 1'b1;
                        state     <= S_SYNC0;
                    end else if (byte_data != 8'hA5) begin
                        state <= S_SYNC0;
                    end
                end
                default: begin
                    frame <= {frame[119:0], byte_data};
                    count <= count + 4'd1;
                    if (count == 4'd15) begin
                        frame_valid <= 1'b1;
                        state       <= S_SYNC0;
                    end
                end
            endcase
        end else if (state != S_SYNC0) begin
            if (idle_timer == TIMEOUT_CYCLES - 1) begin
                parse_err  <= (state == S_DATA);
                state      <= S_SYNC0;
                idle_timer <= 32'd0;
            end else begin
                idle_timer <= idle_timer + 32'd1;
            end
        end
    end
endmodule
