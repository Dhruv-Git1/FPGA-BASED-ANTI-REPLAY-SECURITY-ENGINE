// Checks rtl/strict_counter.v and rtl/sliding_window.v against host/replay_model.py.
// Also checks, after every packet that fails authentication, that neither
// engine's internal state changed.
//
// Vector line (13 hex digits): cmd(4) seq(32) mac_ok(4) strict(4) window(4) reason(4)
// cmd 0 = packet, 1 = session reset, F = end.
`timescale 1ns/1ps
module tb_replay #(parameter W = 64);
    logic        clk = 0;
    logic        rst = 1;
    logic        clear = 0;
    logic        in_valid = 0;
    logic        mac_ok = 0;
    logic [31:0] seq = 0;
    logic        s_valid, s_accept, w_valid, w_accept;
    logic [2:0]  w_reason;
    logic [51:0] vec [0:4095];
    string       vec_dir;
    int          errors = 0, packets = 0, auth_fails = 0;

    always #5 clk = ~clk;

    strict_counter u_strict (.clk(clk), .rst(rst), .clear(clear), .in_valid(in_valid),
        .mac_ok(mac_ok), .seq(seq), .out_valid(s_valid), .accept(s_accept));
    sliding_window #(.W(W)) u_win (.clk(clk), .rst(rst), .clear(clear), .in_valid(in_valid),
        .mac_ok(mac_ok), .seq(seq), .out_valid(w_valid), .accept(w_accept), .reason(w_reason));

    initial begin
        logic [31:0]  exp_before, smax_before;
        logic [W-1:0] mask_before;
        logic         init_before;

        if (!$value$plusargs("VEC=%s", vec_dir)) vec_dir = "sim/vectors";
        $readmemh($sformatf("%s/replay_W%0d.hex", vec_dir, W), vec);
        repeat (3) @(posedge clk);
        rst <= 0;
        for (int i = 0; vec[i][51:48] != 4'hF; i++) begin
            @(posedge clk);
            if (vec[i][51:48] == 4'h1) begin
                clear <= 1;
                @(posedge clk);
                clear <= 0;
                continue;
            end
            exp_before  = u_strict.expected_seq;
            smax_before = u_win.s_max;
            mask_before = u_win.mask;
            init_before = u_win.initialized;
            seq      <= vec[i][47:16];
            mac_ok   <= vec[i][12];
            in_valid <= 1;
            @(posedge clk);
            in_valid <= 0;
            #1;
            packets++;
            if (!s_valid || !w_valid || s_accept !== vec[i][8] || w_accept !== vec[i][4]
                || w_reason !== vec[i][2:0]) begin
                errors++;
                $display("FAIL step %0d seq %0d: expected strict %0d window %0d reason %0d, got %0d %0d %0d",
                         i, vec[i][47:16], vec[i][8], vec[i][4], vec[i][2:0], s_accept, w_accept, w_reason);
            end
            if (!vec[i][12]) begin
                auth_fails++;
                if (u_strict.expected_seq !== exp_before || u_win.s_max !== smax_before
                    || u_win.mask !== mask_before || u_win.initialized !== init_before) begin
                    errors++;
                    $display("FAIL step %0d: failed MAC changed replay state", i);
                end
            end
        end
        $display("replay W=%0d: %0d packets (%0d failed MAC, state checked), %0d errors",
                 W, packets, auth_fails, errors);
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
        $finish;
    end
endmodule
