// Strict sequence-counter replay engine.
//
// Accepts only seq == expected_seq. The counter moves only when the packet is
// authenticated AND accepted. `clear` starts a new test session.
module strict_counter #(
    parameter [31:0] INITIAL_SEQ = 32'd1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        clear,
    input  wire        in_valid,
    input  wire        mac_ok,
    input  wire [31:0] seq,
    output reg         out_valid,
    output reg         accept
);
    reg [31:0] expected_seq;

    wire ok = mac_ok && (seq == expected_seq);

    always @(posedge clk) begin
        out_valid <= 1'b0;
        if (rst || clear) begin
            expected_seq <= INITIAL_SEQ;
        end else if (in_valid) begin
            out_valid <= 1'b1;
            accept    <= ok;
            if (ok)
                expected_seq <= expected_seq + 32'd1;
        end
    end
endmodule
