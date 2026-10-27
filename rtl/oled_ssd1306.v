// Driver for the ZedBoard's on-board 128x32 OLED (SSD1306 controller, wired like
// a Digilent PmodOLED). Write-only SPI: data changes while SCLK is low and the
// controller samples it on the rising edge. Chip select is tied low on the board.
//
// Power-up follows the PmodOLED reference sequence:
//   logic power on (VDD, active low), wait 1 ms, display off,
//   reset pulse, charge pump on, pre-charge period,
//   display power on (VBAT, active low), wait 100 ms,
//   orientation, COM pins, horizontal addressing, display on.
// It then redraws the whole screen forever: 4 pages of 128 one-byte columns.
// Each byte is one 8-pixel column of the character oled_status gives for (row, col).
module oled_ssd1306 #(
    parameter SPI_HALF   = 16,          // clocks per SCLK half period (about 3 MHz)
    parameter DELAY_1MS  = 100_000,
    parameter DELAY_100MS = 10_000_000
) (
    input  wire       clk,
    input  wire       rst,
    output reg  [1:0] row,     // character position requested from oled_status
    output reg  [3:0] col,
    input  wire [6:0] ch,
    output reg        sdin,
    output reg        sclk,
    output reg        dc,      // 0 = command byte, 1 = display data
    output reg        res_n,
    output reg        vbat_n,
    output reg        vdd_n
);
    // Init program. Each entry: {kind[2:0], value[7:0]}.
    localparam [2:0] K_CMD = 3'd0, K_VDD_ON = 3'd1, K_RES_LO = 3'd2, K_RES_HI = 3'd3,
                     K_VBAT_ON = 3'd4, K_WAIT1 = 3'd5, K_WAIT100 = 3'd6, K_END = 3'd7;
    localparam INIT_LEN = 22;
    localparam FRAME_CMDS = 6;

    reg [10:0] init_rom [0:INIT_LEN-1];
    initial begin
        init_rom[0]  = {K_VDD_ON,  8'h00};
        init_rom[1]  = {K_WAIT1,   8'h00};
        init_rom[2]  = {K_CMD,     8'hAE};  // display off
        init_rom[3]  = {K_RES_LO,  8'h00};
        init_rom[4]  = {K_WAIT1,   8'h00};
        init_rom[5]  = {K_RES_HI,  8'h00};
        init_rom[6]  = {K_WAIT1,   8'h00};
        init_rom[7]  = {K_CMD,     8'h8D};  // charge pump
        init_rom[8]  = {K_CMD,     8'h14};  //   enable
        init_rom[9]  = {K_CMD,     8'hD9};  // pre-charge period
        init_rom[10] = {K_CMD,     8'hF1};
        init_rom[11] = {K_VBAT_ON, 8'h00};
        init_rom[12] = {K_WAIT100, 8'h00};
        init_rom[13] = {K_CMD,     8'hA1};  // segment remap (column 127 is SEG0)
        init_rom[14] = {K_CMD,     8'hC8};  // COM scan direction remapped
        init_rom[15] = {K_CMD,     8'hDA};  // COM pins configuration
        init_rom[16] = {K_CMD,     8'h20};  //   sequential, for 32 rows
        init_rom[17] = {K_CMD,     8'h20};  // memory addressing mode
        init_rom[18] = {K_CMD,     8'h00};  //   horizontal
        init_rom[19] = {K_CMD,     8'hAF};  // display on
        init_rom[20] = {K_WAIT1,   8'h00};
        init_rom[21] = {K_END,     8'h00};
    end

    // Sent before every frame: column range 0..127, page range 0..3.
    function [7:0] frame_cmd;
        input [2:0] i;
        case (i)
            3'd0: frame_cmd = 8'h21;
            3'd1: frame_cmd = 8'h00;
            3'd2: frame_cmd = 8'h7F;
            3'd3: frame_cmd = 8'h22;
            3'd4: frame_cmd = 8'h00;
            default: frame_cmd = 8'h03;
        endcase
    endfunction

    localparam [2:0] S_INIT = 3'd0, S_WAIT = 3'd1, S_FCMD = 3'd2, S_DATA = 3'd3, S_SEND = 3'd4;

    reg [2:0]  state, after_send;
    reg [4:0]  pc;
    reg [31:0] wait_cnt;
    reg [2:0]  fcmd_idx;
    reg [8:0]  data_idx;    // 0..511: page in [8:7], column in [6:0]
    reg [7:0]  shift;
    reg [3:0]  bit_cnt;
    reg [15:0] half_cnt;
    reg [1:0]  prep_cnt;
    reg        is_data;     // the byte being sent is display data, not a command
    reg [6:0]  ch_r;
    reg [7:0]  glyph_col_r;
    wire [7:0] glyph_col;

    // Two pipeline registers split the text lookup and the font lookup. Each data
    // byte waits a few clocks after data_idx changes, so both have settled.
    font8x8_rom u_font (.ch(ch_r), .col(data_idx[2:0]), .bits(glyph_col));

    always @(*) begin
        row = data_idx[8:7];
        col = data_idx[6:3];
    end

    wire [10:0] op = init_rom[pc];

    always @(posedge clk) begin
        ch_r        <= ch;
        glyph_col_r <= glyph_col;
        if (rst) begin
            state  <= S_INIT;
            pc     <= 5'd0;
            sclk   <= 1'b1;
            sdin   <= 1'b0;
            dc     <= 1'b0;
            res_n  <= 1'b1;
            vbat_n <= 1'b1;
            vdd_n  <= 1'b1;
        end else begin
            case (state)
                S_INIT: begin
                    pc <= pc + 5'd1;
                    case (op[10:8])
                        K_CMD:     begin dc <= 1'b0; is_data <= 1'b0; shift <= op[7:0]; bit_cnt <= 4'd0;
                                         half_cnt <= 16'd0; after_send <= S_INIT; state <= S_SEND; end
                        K_VDD_ON:  vdd_n  <= 1'b0;
                        K_RES_LO:  res_n  <= 1'b0;
                        K_RES_HI:  res_n  <= 1'b1;
                        K_VBAT_ON: vbat_n <= 1'b0;
                        K_WAIT1:   begin wait_cnt <= DELAY_1MS;   state <= S_WAIT; end
                        K_WAIT100: begin wait_cnt <= DELAY_100MS; state <= S_WAIT; end
                        default:   begin fcmd_idx <= 3'd0; state <= S_FCMD; end  // K_END
                    endcase
                end
                S_WAIT: begin
                    if (wait_cnt == 32'd0)
                        state <= S_INIT;
                    else
                        wait_cnt <= wait_cnt - 32'd1;
                end
                S_FCMD: begin
                    dc         <= 1'b0;
                    is_data    <= 1'b0;
                    shift      <= frame_cmd(fcmd_idx);
                    bit_cnt    <= 4'd0;
                    half_cnt   <= 16'd0;
                    fcmd_idx   <= fcmd_idx + 3'd1;
                    after_send <= (fcmd_idx == FRAME_CMDS - 1) ? S_DATA : S_FCMD;
                    if (fcmd_idx == FRAME_CMDS - 1) begin
                        data_idx <= 9'd0;
                        prep_cnt <= 2'd0;
                    end
                    state      <= S_SEND;
                end
                S_DATA: begin
                    if (prep_cnt != 2'd3) begin
                        prep_cnt <= prep_cnt + 2'd1;
                    end else begin
                        prep_cnt   <= 2'd0;
                        dc         <= 1'b1;
                        is_data    <= 1'b1;
                        shift      <= glyph_col_r;
                        bit_cnt    <= 4'd0;
                        half_cnt   <= 16'd0;
                        after_send <= S_DATA;
                        state      <= S_SEND;
                    end
                end
                default: begin  // S_SEND: 8 bits, most significant first
                    if (half_cnt == SPI_HALF - 1) begin
                        half_cnt <= 16'd0;
                        if (sclk) begin
                            if (bit_cnt == 4'd8) begin
                                // Byte done. Advance to the next data byte or frame.
                                if (is_data) begin
                                    if (data_idx == 9'd511) begin
                                        fcmd_idx <= 3'd0;
                                        state    <= S_FCMD;
                                    end else begin
                                        data_idx <= data_idx + 9'd1;
                                        prep_cnt <= 2'd0;
                                        state    <= S_DATA;
                                    end
                                end else begin
                                    state <= after_send;
                                end
                            end else begin
                                sclk    <= 1'b0;
                                sdin    <= shift[7];
                                shift   <= {shift[6:0], 1'b0};
                                bit_cnt <= bit_cnt + 4'd1;
                            end
                        end else begin
                            sclk <= 1'b1;  // controller samples here
                        end
                    end else begin
                        half_cnt <= half_cnt + 16'd1;
                    end
                end
            endcase
        end
    end
endmodule
