// Authentication stage.
//
// Captures a parsed frame, runs SipHash-2-4 over its first 8 bytes, and
// compares the result with the received tag. Data frames are checked with the
// data key, reset frames with a separate reset key, so a captured data tag can
// never pass as a reset. The frame is held in pkt_r for the whole computation,
// so the verdict always belongs to the frame that produced it. A new
// frame_valid while busy is ignored. At 115200 baud a new frame cannot arrive
// within the 10-clock computation, so this never happens in practice.
//
// Frame layout (pkt[127:120] is the first byte on the wire):
//   [127:112] Device_ID  [111:80] Seq_Num (epoch for resets)  [79:64] Payload  [63:0] MAC_Tag
module auth_stage #(
    parameter [63:0] KD0 = 64'h0706050403020100,  // data key, bytes 00..0f
    parameter [63:0] KD1 = 64'h0f0e0d0c0b0a0908,
    parameter [63:0] KR0 = 64'h1716151413121110,  // reset key, bytes 10..1f
    parameter [63:0] KR1 = 64'h1f1e1d1c1b1a1918
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         frame_valid,
    input  wire         frame_is_reset,
    input  wire [127:0] pkt,
    output reg          auth_done,
    output reg          mac_ok,
    output wire         is_reset,
    output wire [31:0]  seq,
    output wire [15:0]  payload
);
    reg [127:0] pkt_r;
    reg         reset_r;
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

    assign seq      = pkt_r[111:80];
    assign payload  = pkt_r[79:64];
    assign is_reset = reset_r;

    siphash24 u_sip (
        .clk(clk), .rst(rst), .start(sip_start),
        .k0(reset_r ? KR0 : KD0), .k1(reset_r ? KR1 : KD1),
        .m(bswap64(pkt_r[127:64])),
        .busy(sip_busy), .done(sip_done), .tag(sip_tag)
    );

    always @(posedge clk) begin
        sip_start <= 1'b0;
        auth_done <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
        end else if (frame_valid && !busy) begin
            pkt_r     <= pkt;
            reset_r   <= frame_is_reset;
            sip_start <= 1'b1;
            busy      <= 1'b1;
        end else if (sip_done) begin
            mac_ok    <= (sip_tag == bswap64(pkt_r[63:0]));
            auth_done <= 1'b1;
            busy      <= 1'b0;
        end
    end
endmodule
