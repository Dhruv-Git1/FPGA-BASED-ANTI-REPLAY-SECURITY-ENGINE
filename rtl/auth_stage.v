// Authentication stage.
//
// Captures a parsed packet, runs SipHash-2-4 over its first 8 bytes, and
// compares the result with the received tag. The packet is held in pkt_r for
// the whole computation, so the verdict always belongs to the packet that
// produced it. A new frame_valid while busy is ignored. At 115200 baud a new
// frame cannot arrive within the 9-clock computation, so this never happens
// in practice.
//
// Packet layout (pkt[127:120] is the first byte on the wire):
//   [127:112] Device_ID  [111:80] Seq_Num  [79:64] Payload  [63:0] MAC_Tag
module auth_stage #(
    parameter [63:0] K0 = 64'h0706050403020100,
    parameter [63:0] K1 = 64'h0f0e0d0c0b0a0908
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         frame_valid,
    input  wire [127:0] pkt,
    output reg          auth_done,
    output reg          mac_ok,
    output wire [31:0]  seq
);
    reg [127:0] pkt_r;
    reg         sip_start;
    reg         busy;
    wire        sip_busy;
    wire        sip_done;
    wire [63:0] sip_tag;

    // SipHash loads message words and writes its output little-endian, while
    // the packet stores bytes in wire order. Reversing the bytes converts.
    function [63:0] bswap64;
        input [63:0] x;
        integer i;
        for (i = 0; i < 8; i = i + 1)
            bswap64[8*i +: 8] = x[8*(7-i) +: 8];
    endfunction

    assign seq = pkt_r[111:80];

    siphash24 #(.K0(K0), .K1(K1)) u_sip (
        .clk(clk), .rst(rst), .start(sip_start), .m(bswap64(pkt_r[127:64])),
        .busy(sip_busy), .done(sip_done), .tag(sip_tag)
    );

    always @(posedge clk) begin
        sip_start <= 1'b0;
        auth_done <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
        end else if (frame_valid && !busy) begin
            pkt_r     <= pkt;
            sip_start <= 1'b1;
            busy      <= 1'b1;
        end else if (sip_done) begin
            mac_ok    <= (sip_tag == bswap64(pkt_r[63:0]));
            auth_done <= 1'b1;
            busy      <= 1'b0;
        end
    end
endmodule
