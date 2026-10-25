// Checks rtl/siphash24.v against tags computed by host/siphash.py.
// Vector file: one line per case, 8 message bytes then 8 tag bytes, wire order.
// The first case is entry 8 of the official SipHash test vectors.
`timescale 1ns/1ps
module tb_siphash24;
    localparam N = 256;

    logic         clk = 0;
    logic         rst = 1;
    logic         start = 0;
    logic [63:0]  m;
    logic         busy, done;
    logic [63:0]  tag;
    logic [127:0] vec [0:N-1];
    string        vec_dir;
    int           errors = 0;
    int           cycles;

    always #5 clk = ~clk;

    siphash24 dut (.clk(clk), .rst(rst), .start(start), .m(m), .busy(busy), .done(done), .tag(tag));

    function automatic [63:0] bswap64(input [63:0] x);
        for (int i = 0; i < 8; i++) bswap64[8*i +: 8] = x[8*(7-i) +: 8];
    endfunction

    initial begin
        if (!$value$plusargs("VEC=%s", vec_dir)) vec_dir = "sim/vectors";
        $readmemh({vec_dir, "/siphash.hex"}, vec);
        repeat (3) @(posedge clk);
        rst <= 0;
        for (int i = 0; i < N; i++) begin
            @(posedge clk);
            m     <= bswap64(vec[i][127:64]);
            start <= 1;
            @(posedge clk);
            start  <= 0;
            cycles = 1;
            while (!done) begin @(posedge clk); cycles++; end
            if (tag !== bswap64(vec[i][63:0])) begin
                errors++;
                $display("FAIL case %0d: msg %h expected %h got %h", i, vec[i][127:64],
                         bswap64(vec[i][63:0]), tag);
            end
        end
        $display("siphash24: %0d cases, %0d errors, %0d clocks from start to done",
                 N, errors, cycles);
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
        $finish;
    end
endmodule
