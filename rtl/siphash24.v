// SipHash-2-4 for one fixed-length 8-byte message.
//
// The message fills exactly one 64-bit block, so the computation is always:
//   block m        : v3 ^= m, 2 SipRounds, v0 ^= m
//   length block b : v3 ^= b, 2 SipRounds, v0 ^= b   (b = 8 << 56)
//   finalization   : v2 ^= ff, 4 SipRounds, tag = v0 ^ v1 ^ v2 ^ v3
// One SipRound is done per clock, and the block XORs are folded into the
// same clock edge, so `done` pulses 8 clocks after `start`.
//
// `m` must already be the little-endian load of the 8 message bytes, as the
// SipHash specification defines it. `tag` is the 64-bit SipHash output word.
module siphash24 #(
    parameter [63:0] K0 = 64'h0706050403020100,  // key bytes 00..07, little-endian
    parameter [63:0] K1 = 64'h0f0e0d0c0b0a0908   // key bytes 08..0f, little-endian
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [63:0] m,
    output reg         busy,
    output reg         done,
    output reg  [63:0] tag
);
    localparam [63:0] LEN_BLOCK = 64'h0800000000000000;

    localparam [1:0] PH_MSG = 2'd0, PH_LEN = 2'd1, PH_FIN = 2'd2;

    reg [63:0] v0, v1, v2, v3;
    reg [63:0] m_r;
    reg [1:0]  phase;
    reg [1:0]  rnd;

    function [63:0] rotl;
        input [63:0] x;
        input integer b;
        rotl = (x << b) | (x >> (64 - b));
    endfunction

    // One SipRound, written exactly as in the specification.
    reg [63:0] a0, a1, a2, a3;
    always @(*) begin
        a0 = v0 + v1;
        a1 = rotl(v1, 13) ^ a0;
        a0 = rotl(a0, 32);
        a2 = v2 + v3;
        a3 = rotl(v3, 16) ^ a2;
        a0 = a0 + a3;
        a3 = rotl(a3, 21) ^ a0;
        a2 = a2 + a1;
        a1 = rotl(a1, 17) ^ a2;
        a2 = rotl(a2, 32);
    end

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
        end else if (start && !busy) begin
            v0    <= K0 ^ 64'h736f6d6570736575;
            v1    <= K1 ^ 64'h646f72616e646f6d;
            v2    <= K0 ^ 64'h6c7967656e657261;
            v3    <= K1 ^ 64'h7465646279746573 ^ m;
            m_r   <= m;
            phase <= PH_MSG;
            rnd   <= 2'd0;
            busy  <= 1'b1;
        end else if (busy) begin
            v0  <= a0;
            v1  <= a1;
            v2  <= a2;
            v3  <= a3;
            rnd <= rnd + 2'd1;
            case (phase)
                PH_MSG: if (rnd == 2'd1) begin
                    v0    <= a0 ^ m_r;
                    v3    <= a3 ^ LEN_BLOCK;
                    phase <= PH_LEN;
                    rnd   <= 2'd0;
                end
                PH_LEN: if (rnd == 2'd1) begin
                    v0    <= a0 ^ LEN_BLOCK;
                    v2    <= a2 ^ 64'h00000000000000ff;
                    phase <= PH_FIN;
                    rnd   <= 2'd0;
                end
                default: if (rnd == 2'd3) begin
                    tag  <= a0 ^ a1 ^ a2 ^ a3;
                    done <= 1'b1;
                    busy <= 1'b0;
                end
            endcase
        end
    end
endmodule
