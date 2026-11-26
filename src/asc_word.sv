// A word of 32 flops that takes d in a clock with we high, for the caches.
//
// A flop with an enable is a flop and a multiplexer for every bit. Here
// the word has a gate in its clock, which saves the multiplexers, a third
// of the area of a cache. The gate is a cell of the sky130 library, which
// a simulator and an FPGA do not have; they get the flop with an enable,
// which does the same. The flops have no reset: a cache reads a word only
// after it has written it.
module asc_word (
    input  logic        clk,
    input  logic        we,
    input  logic [31:0] d,
    output logic [31:0] q
);
`ifdef ASC_SKY130_LATCH
    // Latches in place of flops, a quarter smaller again. The gated clock
    // is high for the first half of the clock after we; d comes from a
    // register that stands still in that clock.
    logic gclk;

    sky130_fd_sc_hd__dlclkp_1 gate (
        .CLK  (clk),
        .GATE (we),
        .GCLK (gclk)
    );

    genvar i;

    generate
        for (i = 0; i < 32; i++) begin : bits
            sky130_fd_sc_hd__dlxtp_1 latch (
                .D    (d[i]),
                .GATE (gclk),
                .Q    (q[i])
            );
        end
    endgenerate
`elsif ASC_SKY130
    logic gclk;

    sky130_fd_sc_hd__dlclkp_1 gate (
        .CLK  (clk),
        .GATE (we),
        .GCLK (gclk)
    );

    always_ff @(posedge gclk) begin
        q <= d;
    end
`else
    always_ff @(posedge clk) begin
        if (we) begin
            q <= d;
        end
    end
`endif
endmodule
