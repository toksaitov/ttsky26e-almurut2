// The instruction cache of the Almurut II CPU.
//
// Every fetch is a transaction on the bus, hundreds of clocks long, and
// seven of ten transactions are fetches. The cache keeps the words that
// the bus has delivered, so a loop that fits runs without the bus.
//
// LINES lines of eight words. A line holds words of one block of 32 bytes
// of the address space; its tag is the rest of the address. A word has a
// valid bit of its own: a line fills as the program walks through it, with
// no read ahead. The address is the one of the program, before the
// translation, so a hit needs no translation; the CPU empties the cache
// whenever a translation or the mode may have changed (flush).
//
// The read has no clock. The data flops have no reset: a word is read only
// with its valid bit set.
module asc_icache #(
    parameter int LINES = 8
) (
    input  logic        clk,
    input  logic        flush,
    input  logic [31:0] addr,
    output logic        hit,
    output logic [31:0] rdata,
    input  logic        fill,
    input  logic [31:0] wdata
);
    localparam int LB    = $clog2(LINES);
    localparam int TAG   = 32 - 5 - LB;
    localparam int SLOTS = LINES * 8;

    logic [TAG-1:0] tag_q   [0:LINES-1];
    logic [7:0]     valid_q [0:LINES-1];
    logic [31:0]    data_q  [0:SLOTS-1];

    logic [LB-1:0]   line;
    logic [2:0]      word;
    logic [LB+2:0]   slot;
    logic [TAG-1:0]  tag;
    logic            same;

    always_comb begin
        line  = addr[5 +: LB];
        word  = addr[4:2];
        slot  = addr[2 +: LB + 3];
        tag   = addr[31 -: TAG];
        same  = (tag_q[line] == tag);
        hit   = same && valid_q[line][word] && (addr[1:0] == 2'b00);
        rdata = data_q[slot];
    end

    always_ff @(posedge clk) begin
        for (int i = 0; i < LINES; i++) begin
            if (flush) begin
                valid_q[i] <= 8'd0;
            end else if (fill && line == i[LB-1:0]) begin
                // A word of another block takes the line over
                tag_q[i]   <= tag;
                valid_q[i] <= (same ? valid_q[i] : 8'd0) | (8'd1 << word);
            end
        end
    end

    // Each word is a module of its own with a gate in its clock (asc_word.sv)
    genvar i;

    generate
        for (i = 0; i < SLOTS; i++) begin : words
            asc_word store (
                .clk (clk),
                .we  (fill && (slot == i[LB+2:0])),
                .d   (wdata),
                .q   (data_q[i])
            );
        end
    endgenerate
endmodule
