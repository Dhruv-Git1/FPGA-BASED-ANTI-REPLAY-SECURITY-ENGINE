// RFC 4303-style sliding-window replay engine with window size W.
//
// State: initialized, s_max (highest accepted sequence number) and mask,
// where mask[0] is s_max and mask[k] is s_max - k. Rules (spec section 5.2):
//   not initialized, or seq > s_max : accept (NEW), shift mask by the advance
//   s_max - seq >= W                : reject (STL, stale)
//   mask[s_max - seq] set           : reject (DUP, duplicate)
//   otherwise                       : accept (INW), set that bit
//   mac_ok low                      : reject (AUT), state untouched
// Sequence numbers are not allowed to wrap within a session.
module sliding_window #(
    parameter W = 64
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        clear,
    input  wire        in_valid,
    input  wire        mac_ok,
    input  wire [31:0] seq,
    output reg         out_valid,
    output reg         accept,
    output reg  [2:0]  reason
);
    localparam [2:0] R_NEW = 3'd0, R_INW = 3'd1, R_DUP = 3'd2, R_STL = 3'd3, R_AUT = 3'd4;
    localparam AW = $clog2(W);
    localparam [W-1:0] ONE = {{(W-1){1'b0}}, 1'b1};

    reg          initialized;
    reg [31:0]   s_max;
    reg [W-1:0]  mask;

    wire [31:0] advance = seq - s_max;
    wire [31:0] age     = s_max - seq;
    wire        newer   = !initialized || (seq > s_max);
    wire        in_win  = (age < W);
    wire        seen    = mask[age[AW-1:0]];

    always @(posedge clk) begin
        out_valid <= 1'b0;
        if (rst || clear) begin
            initialized <= 1'b0;
            s_max       <= 32'd0;
            mask        <= {W{1'b0}};
        end else if (in_valid) begin
            out_valid <= 1'b1;
            if (!mac_ok) begin
                accept <= 1'b0;
                reason <= R_AUT;
            end else if (newer) begin
                accept      <= 1'b1;
                reason      <= R_NEW;
                initialized <= 1'b1;
                s_max       <= seq;
                if (!initialized || advance >= W)
                    mask <= ONE;
                else
                    mask <= (mask << advance[AW-1:0]) | ONE;
            end else if (!in_win) begin
                accept <= 1'b0;
                reason <= R_STL;
            end else if (seen) begin
                accept <= 1'b0;
                reason <= R_DUP;
            end else begin
                accept <= 1'b1;
                reason <= R_INW;
                mask   <= mask | (ONE << age[AW-1:0]);
            end
        end
    end
endmodule
