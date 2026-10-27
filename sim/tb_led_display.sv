// Checks rtl/led_display.v: boot sweep, verdict stage walk, blinking rejection
// reasons, session-clear flash, parse-error blink and host pass/fail patterns.
// One display step is 10 clocks here instead of 125 ms.
`timescale 1ns/1ps
module tb_led_display;
    localparam TICK = 10;

    logic       clk = 0, rst = 1;
    logic       verdict_valid = 0, mac_ok = 0, strict_accept = 0, window_accept = 0;
    logic [2:0] window_reason = 0;
    logic       session_clear = 0, parse_err = 0, host_pass = 0, host_fail = 0;
    logic [7:0] led;
    int         errors = 0;

    always #5 clk = ~clk;

    led_display #(.TICK_CYCLES(TICK), .STAGE_TICKS(2)) dut (.*);

    // Record each new value of (led & mask) for n display steps.
    task automatic watch(input int n_ticks, input logic [7:0] mask, ref logic [7:0] seen[$]);
        seen.delete();
        repeat (n_ticks * TICK) begin
            @(posedge clk);
            #1;
            if (seen.size() == 0 || seen[$] != (led & mask)) seen.push_back(led & mask);
        end
    endtask

    task automatic pulse(ref logic sig);
        @(negedge clk);
        sig = 1;
        @(negedge clk);
        sig = 0;
        @(posedge clk);  // let the registered LED output catch up
        @(posedge clk);
    endtask

    task automatic verdict(input logic m, s, w, input logic [2:0] r);
        mac_ok = m; strict_accept = s; window_accept = w; window_reason = r;
        pulse(verdict_valid);
    endtask

    function automatic string fmt(logic [7:0] q[$]);
        string s = "";
        foreach (q[i]) s = {s, $sformatf("%02h ", q[i])};
        return s;
    endfunction

    task automatic expect_prefix(string name, logic [7:0] got[$], logic [7:0] want[$]);
        bit ok = got.size() >= want.size();
        for (int i = 0; ok && i < want.size(); i++) ok = (got[i] == want[i]);
        if (!ok) begin
            errors++;
            $display("FAIL %s: want %s got %s", name, fmt(want), fmt(got));
        end
    endtask

    task automatic expect_values(string name, logic [7:0] got[$], logic [7:0] allowed[$]);
        foreach (got[i]) begin
            bit found = 0;
            foreach (allowed[j]) if (got[i] == allowed[j]) found = 1;
            if (!found) begin
                errors++;
                $display("FAIL %s: unexpected %02h in %s", name, got[i], fmt(got));
                return;
            end
        end
        if (got.size() < allowed.size()) begin
            errors++;
            $display("FAIL %s: expected all of %s, saw %s", name, fmt(allowed), fmt(got));
        end
    endtask

    initial begin
        logic [7:0] seen[$];
        logic [7:0] want[$];

        // Boot: 0..7..1 twice, then idle with only the heartbeat.
        repeat (3) @(posedge clk);
        rst <= 0;
        watch(30, 8'hFF, seen);
        want = {};
        for (int s = 0; s < 28; s++) begin
            int p = s % 14;
            want.push_back(8'd1 << ((p < 8) ? p : 14 - p));
        end
        expect_prefix("boot sweep", seen, want);
        if ((seen[$] & 8'h7F) != 0) begin errors++; $display("FAIL boot: not idle afterwards"); end

        // Accepted by both engines: stages fill in, result held steady.
        verdict(1, 1, 1, 3'd0);
        watch(12, 8'h7F, seen);
        expect_prefix("accept walk", seen, '{8'h01, 8'h03, 8'h0B, 8'h1B});
        if (seen[$] != 8'h1B) begin errors++; $display("FAIL accept hold: %02h", seen[$]); end

        // MAC failure: LD2 lights, engines stay dark, LD2 blinks while held.
        verdict(0, 0, 0, 3'd4);
        watch(16, 8'h7F, seen);
        expect_prefix("mac fail walk", seen, '{8'h01, 8'h05});
        expect_values("mac fail hold", seen, '{8'h01, 8'h05});

        // Duplicate: MAC ok, both engines reject, LD5 blinks.
        verdict(1, 0, 0, 3'd2);
        watch(16, 8'h7F, seen);
        expect_prefix("duplicate walk", seen, '{8'h01, 8'h03, 8'h23});
        expect_values("duplicate hold", seen, '{8'h01, 8'h03, 8'h23});

        // Stale: LD6 blinks.
        verdict(1, 0, 0, 3'd3);
        watch(16, 8'h7F, seen);
        expect_values("stale", seen, '{8'h01, 8'h03, 8'h43});

        // Session clear: all on, off, all on, off, then idle.
        pulse(session_clear);
        watch(6, 8'hFF, seen);
        expect_prefix("clear flash", seen, '{8'hFF, 8'h00, 8'hFF, 8'h00});

        // Parse error: only LD0 blinks (LD7 is the heartbeat).
        pulse(parse_err);
        watch(6, 8'h7F, seen);
        expect_values("parse error", seen, '{8'h00, 8'h01});

        // Host pass: fill one by one, then all on and steady.
        pulse(host_pass);
        watch(14, 8'hFF, seen);
        expect_prefix("pass fill", seen, '{8'h01, 8'h03, 8'h07, 8'h0F, 8'h1F, 8'h3F, 8'h7F, 8'hFF});
        if (seen[$] != 8'hFF) begin errors++; $display("FAIL pass hold"); end

        // Host fail: all eight blink.
        pulse(host_fail);
        watch(6, 8'hFF, seen);
        expect_values("fail blink", seen, '{8'hFF, 8'h00});

        $display("led_display: %0d errors", errors);
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
        $finish;
    end
endmodule
