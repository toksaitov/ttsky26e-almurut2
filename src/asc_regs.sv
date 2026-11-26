// The register file of the Almurut II CPU: 12 words of 32 bits.
//
//   word   register
//   0-7    r0-r7
//   8      fp
//   9      the stack pointer of kernel mode
//   10     lr
//   11     the stack pointer of user mode (the control register cr6)
//
// One word is read at a time and one is written at a time, so the file
// needs one multiplexer for reading and one decoder for writing. The read
// has no clock: rdata follows raddr. The CPU reads the two operands of an
// instruction in two clocks.
//
// ip and flags are not here: the CPU keeps them next to the logic that
// changes them.
//
// dbg shows all twelve words at once, word 0 in its low bits, for the
// debug port. Nothing of the CPU reads it.
module asc_regs (
    input  logic        clk,
    input  logic        rst,
    input  logic [3:0]  raddr,
    output logic [31:0] rdata,
    input  logic        we,
    input  logic [3:0]  waddr,
    input  logic [31:0] wdata,
    output logic [383:0] dbg
);
    localparam int WORDS = 12;

    logic [31:0] words_q [0:WORDS-1];

    // Each word has its own write enable. Written as words_q[waddr], the
    // file comes out of synthesis with 16 words, four of them for the
    // numbers that no register has.
    always_ff @(posedge clk) begin
        for (int i = 0; i < WORDS; i++) begin
            if (rst) begin
                words_q[i] <= '0;
            end else if (we && waddr == i[3:0]) begin
                words_q[i] <= wdata;
            end
        end
    end

    always_comb begin
        rdata = '0;
        for (int i = 0; i < WORDS; i++) begin
            if (raddr == i[3:0]) begin
                rdata = words_q[i];
            end
            dbg[32 * i +: 32] = words_q[i];
        end
    end
endmodule
