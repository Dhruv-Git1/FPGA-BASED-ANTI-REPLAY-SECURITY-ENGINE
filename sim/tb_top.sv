// Full-system test of rtl/top_zedboard.v through its UART pins.
//
// Drives real UART bit waveforms in, decodes the telemetry text coming out, and
// compares each line with sim/vectors/system_W<W>_expected.txt. The UART runs at
// 16 clocks per bit here so the simulation is fast. The logic is the same as on
// the board, only the timing parameters are scaled.
//
// Stimulus commands: "B xx" send byte, "E xx" send byte with a broken stop bit,
// "G n" stay idle for n bit times, "W" wait for the next telemetry line, "X" end.
`timescale 1ns/1ps
module tb_top #(parameter W = 64);
    localparam CPB          = 16;          // clocks per UART bit
    localparam TIMEOUT_BITS = 300;         // must match SIM_TIMEOUT_BITS in host/gen_vectors.py

    logic       clk = 0;
    logic       rx = 1;
    logic       tx;
    logic       btn = 0;
    logic [7:0] led;
    string      vec_dir;
    string      lines [$];
    int         errors = 0, checked = 0, waited = 0;
    int         first_latency = -1;

    always #5 clk = ~clk;

    top_zedboard #(
        .W(W), .CLK_HZ(CPB * 100_000), .BAUD(100_000),
        .TIMEOUT_CYCLES(TIMEOUT_BITS * CPB), .DEBOUNCE_CYCLES(16), .LED_TICK_CYCLES(64)
    ) dut (.clk(clk), .btn_c(btn), .uart_rx(rx), .uart_tx(tx), .led(led));

    task automatic send_byte(input [7:0] b, input bit good_stop);
        rx = 0;
        repeat (CPB) @(posedge clk);
        for (int i = 0; i < 8; i++) begin
            rx = b[i];
            repeat (CPB) @(posedge clk);
        end
        rx = good_stop;
        repeat (CPB) @(posedge clk);
        rx = 1;
    endtask

    // Telemetry receiver: collect characters into lines.
    initial begin
        string cur = "";
        logic [7:0] ch;
        forever begin
            @(negedge tx);
            repeat (CPB + CPB / 2) @(posedge clk);
            for (int i = 0; i < 8; i++) begin
                ch[i] = tx;
                repeat (CPB) @(posedge clk);
            end
            if (ch == 8'h0A) begin
                lines.push_back(cur);
                cur = "";
            end else if (ch != 8'h0D) begin
                cur = {cur, string'(ch)};
            end
        end
    end

    function automatic string chomp(input string s);
        while (s.len() > 0 && (s[s.len()-1] == 8'h0A || s[s.len()-1] == 8'h0D))
            s = s.substr(0, s.len() - 2);
        return s;
    endfunction

    initial begin
        int    fd, efd, val, timeout;
        string cmd, exp, got;

        if (!$value$plusargs("VEC=%s", vec_dir)) vec_dir = "sim/vectors";
        fd  = $fopen($sformatf("%s/system_W%0d.txt", vec_dir, W), "r");
        efd = $fopen($sformatf("%s/system_W%0d_expected.txt", vec_dir, W), "r");
        if (fd == 0 || efd == 0) begin
            $display("RESULT: FAIL (cannot open vector files in %s)", vec_dir);
            $finish;
        end
        repeat (40) @(posedge clk);

        while ($fscanf(fd, "%s", cmd) == 1 && cmd != "X") begin
            case (cmd)
                "B": begin void'($fscanf(fd, "%h", val)); send_byte(val[7:0], 1); end
                "E": begin void'($fscanf(fd, "%h", val)); send_byte(val[7:0], 0); end
                "G": begin void'($fscanf(fd, "%d", val)); repeat (val * CPB) @(posedge clk); end
                "W": begin
                    waited++;
                    timeout = 0;
                    while (lines.size() + checked < waited && timeout < 200 * CPB * 10) begin
                        @(posedge clk);
                        timeout++;
                    end
                    if (lines.size() + checked < waited) begin
                        errors++;
                        $display("FAIL: no telemetry line for wait #%0d", waited);
                        checked++;
                        void'($fgets(exp, efd));
                        continue;
                    end
                    got = lines.pop_front();
                    void'($fgets(exp, efd));
                    exp = chomp(exp);
                    checked++;
                    if (exp.substr(0, 3) == "SEQ=") begin
                        if (got.len() < 37 || got.substr(0, 36) != exp) begin
                            errors++;
                            $display("FAIL line %0d: expected '%s' got '%s'", checked, exp, got);
                        end else if (first_latency < 0) begin
                            first_latency = got.substr(42, 45).atohex();
                        end
                    end else if (got != exp) begin
                        errors++;
                        $display("FAIL line %0d: expected '%s' got '%s'", checked, exp, got);
                    end
                end
                default: begin
                    $display("RESULT: FAIL (unknown command '%s')", cmd);
                    $finish;
                end
            endcase
        end

        // Button press must also reset the session and report RST.
        btn = 1;
        repeat (200) @(posedge clk);
        btn = 0;
        repeat (5000) @(posedge clk);
        got = (lines.size() > 0) ? lines.pop_front() : "<none>";
        if (got != "RST") begin
            errors++;
            $display("FAIL: button press gave '%s', expected RST", got);
        end
        checked++;

        $display("top W=%0d: %0d telemetry lines checked, %0d errors, latency %0d clocks",
                 W, checked, errors, first_latency);
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
        $finish;
    end
endmodule
