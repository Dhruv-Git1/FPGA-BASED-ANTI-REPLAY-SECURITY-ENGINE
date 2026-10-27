// Checks rtl/oled_status.v and rtl/oled_ssd1306.v together.
//
// The testbench decodes the SPI lines the way the SSD1306 would: a bit on each
// rising SCLK edge, 8 bits per byte, D/C telling command from data. It checks the
// power-up order, then rebuilds each 128x32 frame, turns every 8x8 cell back
// into a character with the same font, and compares the 4 text lines with the
// expected screen. Delays and display steps are shortened.
`timescale 1ns/1ps
module tb_oled;
    localparam TICK = 20_000, D1 = 20, D100 = 400;

    logic        clk = 0, rst = 1;
    logic        verdict_valid = 0, mac_ok = 0, strict_accept = 0, window_accept = 0;
    logic [2:0]  window_reason = 0;
    logic        policy_used = 0, final_accept = 0, door_open = 0, policy_live = 0;
    logic [15:0] cmd = 0;
    logic [31:0] seq = 0;
    logic [15:0] sc_acc = 0, sc_rej = 0, sw_acc = 0, sw_rej = 0;
    logic        reset_ok = 0, reset_button = 0, reset_denied = 0;
    logic        parse_err = 0, host_pass = 0, host_fail = 0;
    logic [1:0]  row;
    logic [3:0]  col;
    logic [6:0]  ch;
    logic        sdin, sclk, dc, res_n, vbat_n, vdd_n;
    int          errors = 0;

    always #5 clk = ~clk;

    oled_status #(.W(64), .TICK_CYCLES(TICK), .STAGE_TICKS(3)) u_status (
        .clk(clk), .rst(rst), .verdict_valid(verdict_valid), .mac_ok(mac_ok),
        .strict_accept(strict_accept), .window_accept(window_accept),
        .window_reason(window_reason), .policy_used(policy_used), .final_accept(final_accept),
        .cmd(cmd), .seq(seq), .door_open(door_open), .policy_live(policy_live),
        .sc_acc(sc_acc), .sc_rej(sc_rej), .sw_acc(sw_acc), .sw_rej(sw_rej),
        .reset_ok(reset_ok), .reset_button(reset_button), .reset_denied(reset_denied),
        .parse_err(parse_err), .host_pass(host_pass), .host_fail(host_fail),
        .row(row), .col(col), .ch(ch));

    oled_ssd1306 #(.SPI_HALF(1), .DELAY_1MS(D1), .DELAY_100MS(D100)) u_oled (
        .clk(clk), .rst(rst), .row(row), .col(col), .ch(ch),
        .sdin(sdin), .sclk(sclk), .dc(dc), .res_n(res_n), .vbat_n(vbat_n), .vdd_n(vdd_n));

    // Font copy for decoding, read out of the same ROM.
    logic [6:0] f_ch;
    logic [2:0] f_col;
    logic [7:0] f_bits;
    logic [7:0] font [0:127][0:7];
    font8x8_rom u_font_ref (.ch(f_ch), .col(f_col), .bits(f_bits));

    // ---- SPI decoder ------------------------------------------------------
    logic [7:0] frame_buf [0:511];
    logic [7:0] last_frame [0:511];
    int         frames = 0, data_pos = -1;
    logic [7:0] cmd_hist [$];
    int         n_cmds = 0;
    time        t_vbat_on = 0, t_display_on = 0;

    initial begin
        logic [7:0] b;
        int nb = 0;
        // SCLK goes from unknown to high during reset. Do not count that as a bit.
        wait (rst == 0);
        forever begin
            @(posedge sclk);
            b = {b[6:0], sdin};
            nb++;
            if (nb == 8) begin
                nb = 0;
                if (!dc) begin
                    cmd_hist.push_back(b);
                    n_cmds++;
                    if (b == 8'hAF && t_display_on == 0) t_display_on = $time;
                    // The frame header ends with 22 00 03, data follows.
                    if (cmd_hist.size() >= 3 && cmd_hist[$-2] == 8'h22 && cmd_hist[$-1] == 8'h00
                        && b == 8'h03) data_pos = 0;
                end else if (data_pos >= 0) begin
                    frame_buf[data_pos] = b;
                    data_pos++;
                    if (data_pos == 512) begin
                        last_frame = frame_buf;
                        frames++;
                        data_pos = -1;
                    end
                end
            end
        end
    end

    always @(negedge vbat_n) t_vbat_on = $time;

    // ---- helpers -------------------------------------------------------------
    function automatic string decode_row(int r);
        string s = "";
        for (int c = 0; c < 16; c++) begin
            int found = -1;
            for (int code = 32; code < 127 && found < 0; code++) begin
                bit same = 1;
                for (int x = 0; x < 8; x++)
                    if (font[code][x] != last_frame[r * 128 + c * 8 + x]) same = 0;
                if (same) found = code;
            end
            s = {s, (found < 0) ? "?" : string'(byte'(found))};
        end
        return s;
    endfunction

    // Wait for two fresh frames so the whole picture was drawn after any change.
    task automatic expect_screen(string name, string l0, string l1, string l2, string l3);
        string want [4] = '{l0, l1, l2, l3};
        int start = frames;
        $display("[%0t] checking %s", $time, name);
        while (frames < start + 2) @(posedge clk);
        for (int r = 0; r < 4; r++) begin
            string got = decode_row(r);
            if (want[r] != "*" && got != want[r]) begin
                errors++;
                $display("FAIL %s row %0d: want '%s' got '%s'", name, r, want[r], got);
            end
        end
    endtask

    task automatic pulse(ref logic sig);
        @(negedge clk);
        sig = 1;
        @(negedge clk);
        sig = 0;
    endtask

    task automatic wait_ticks(int n);
        repeat (n * TICK) @(posedge clk);
    endtask

    // mac, strict, window, reason, policy (0 SC / 1 SW), final, command, sequence
    task automatic verdict(logic m, s, w, logic [2:0] r, logic pol, fin, logic [15:0] c,
                           logic [31:0] q);
        mac_ok = m; strict_accept = s; window_accept = w; window_reason = r;
        policy_used = pol; final_accept = fin; cmd = c; seq = q;
        pulse(verdict_valid);
    endtask

    initial begin
        for (int code = 0; code < 128; code++)
            for (int x = 0; x < 8; x++) begin
                f_ch = code; f_col = x; #1;
                font[code][x] = f_bits;
            end

        repeat (5) @(posedge clk);
        rst = 0;

        // Power-up order: logic power first, display power later, then display on
        // no earlier than the 100 ms wait after display power.
        @(negedge vdd_n);
        if (vbat_n !== 1'b1) begin errors++; $display("FAIL power: VBAT on before VDD"); end
        @(negedge res_n);
        @(posedge res_n);
        @(negedge vbat_n);
        if (n_cmds < 5) begin errors++; $display("FAIL power: VBAT on before charge pump setup"); end
        wait (t_display_on != 0);
        if (t_display_on - t_vbat_on < D100 * 10) begin
            errors++;
            $display("FAIL power: display on %0t after VBAT, expected at least %0t", t_display_on - t_vbat_on, D100 * 10);
        end

        expect_screen("boot", "ANTI-REPLAY FPGA", "MAC: SIPHASH-2-4", "*", "WINDOW SIZE  64 ");
        wait_ticks(17);
        sc_acc = 16'h0012; sc_rej = 16'h0003; sw_acc = 16'h0014; sw_rej = 16'h0001;
        expect_screen("summary", "POLICY SC  W= 64", "DOOR CLOSED     ", "SC +0012 -0003  ", "SW +0014 -0001  ");

        // Out of order under SW: strict says no, window says yes, final accept.
        // First only the CMD line shows, then one line per stage.
        verdict(1, 0, 1, 3'd0, 1, 1, 16'h0001, 32'h4);
        expect_screen("walk stage 0", "CMD: OPEN   0004", "                ", "                ", "                ");
        wait_ticks(13);
        expect_screen("accept", "CMD: OPEN   0004", "AUTH: PASS      ", "POLICY: SW S- W+", "RESULT: ACCEPT  ");

        verdict(1, 0, 1, 3'd0, 0, 0, 16'h0002, 32'h4);
        wait_ticks(13);
        expect_screen("strict reject", "CMD: CLOSE  0004", "AUTH: PASS      ", "POLICY: SC S- W+", "RESULT: REJ SEQ ");

        verdict(1, 0, 0, 3'd2, 1, 0, 16'h0003, 32'h3);
        wait_ticks(13);
        expect_screen("replay", "CMD: STATUS 0003", "*", "POLICY: SW S- W-", "RESULT: REJ DUP ");

        verdict(1, 0, 0, 3'd3, 1, 0, 16'h1234, 32'h1);
        wait_ticks(13);
        expect_screen("stale", "CMD: DATA   0001", "*", "*", "RESULT: REJ OLD ");

        verdict(0, 0, 0, 3'd4, 1, 0, 16'h0001, 32'h000F4240);
        wait_ticks(13);
        expect_screen("tampered", "CMD: OPEN   4240", "AUTH: FAIL      ", "POLICY: SW S- W-", "RESULT: REJ AUTH");

        // The verdict stays 3 s, then the summary returns with live values.
        door_open = 1; policy_live = 1;
        wait_ticks(26);
        expect_screen("summary again", "POLICY SW  W= 64", "DOOR OPEN       ", "*", "*");

        seq = 32'h0000000A;
        pulse(reset_ok);
        expect_screen("signed reset", "SESSION RESET   ", "EPOCH 0000000A  ", "SIGNED TAG OK   ", "COUNTERS CLEARED");

        pulse(reset_button);
        expect_screen("button reset", "SESSION RESET   ", "BY BUTTON BTNC  ", "                ", "COUNTERS CLEARED");

        pulse(reset_denied);
        expect_screen("denied reset", "RESET DENIED!   ", "BAD TAG OR OLD  ", "STATE UNCHANGED ", "POSSIBLE ATTACK ");

        pulse(parse_err);
        expect_screen("frame error", "FRAME ERROR     ", "BAD BYTE OR GAP ", "FRAME DISCARDED ", "WAITING FOR A55A");

        pulse(host_pass);
        expect_screen("pass", "****************", "ALL TESTS PASSED", "PACKETS   0005  ", "****************");

        pulse(host_fail);
        expect_screen("fail", "!!!!!!!!!!!!!!!!", "TEST RUN FAILED ", "SEE PC LOG      ", "!!!!!!!!!!!!!!!!");

        $display("oled: %0d frames decoded, %0d errors", frames, errors);
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
        $finish;
    end
endmodule
