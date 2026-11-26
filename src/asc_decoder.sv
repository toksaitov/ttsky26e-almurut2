// The instruction decoder of the Almurut II CPU: it tells whether a word
// is an instruction, and whether the instruction is for kernel mode only.
//
// The word (see the table of encodings in asc2-emulated/asc.h):
//
//   31            16 15  12 11   8 7      0
//   +---------------+------+------+--------+
//   |      imm      |  ra  |  rb  | opcode |
//   +---------------+------+------+--------+
//
// Bit 7 of the opcode selects the immediate form, in which imm takes the
// place of register A as the first operand.
//
// A word is an instruction if its opcode is one of the table and every
// field holds what the instruction allows there: the number of a
// register (0 to 12), the number of a control register (0 to 8), the
// number of a register of the array of the dot products (0 to 3 for the
// weights of a row and 4 to 7 for its inputs, for the DOT_ROWS rows that
// the array has), or zero in a field that the instruction does not use.
// The CPU raises the exception of an invalid instruction for any other
// word, so a number that is not an instruction today can become one in a
// later chip.
//
// array is high for an instruction that names a register of the array.
// A user program may run it only while the bit A of cr0 is set.
module asc_decoder #(
    parameter int DOT_ROWS = 3
) (
    input  logic [31:0] inst,
    output logic        valid,
    output logic        privileged,
    output logic        array
);
    // What a register field may hold
    localparam logic [1:0] R_ZERO = 2'd0;  // zero: the field is not used
    localparam logic [1:0] R_REG  = 2'd1;  // the number of a register
    localparam logic [1:0] R_CTRL = 2'd2;  // the number of a control register
    localparam logic [1:0] R_DOT  = 2'd3;  // the number of a register of the array

    // What the immediate field may hold
    localparam logic [1:0] I_ZERO = 2'd0;  // zero: the field is not used
    localparam logic [1:0] I_ANY  = 2'd1;  // any number
    localparam logic [1:0] I_REG  = 2'd2;  // the number of a register
    localparam logic [1:0] I_BYTE = 2'd3;  // a number from 0 to 255

    localparam logic [3:0] REGS  = 4'd13;
    localparam logic [3:0] CTRLS = 4'd9;

    // dotm adds the sum of every row to a register from r0 to r7, so this
    // is the last register that it may start from
    localparam logic [3:0] DOTM_LAST = 4'(8 - DOT_ROWS);

    logic [7:0]  opcode;
    logic [3:0]  rb;
    logic [3:0]  ra;
    logic [15:0] imm;

    logic        known;
    logic [1:0]  ra_rule;
    logic [1:0]  rb_rule;
    logic [1:0]  imm_rule;
    logic        ra_ok;
    logic        rb_ok;
    logic        imm_ok;
    logic        dotm_ok;

    always_comb begin
        opcode = inst[7:0];
        rb     = inst[11:8];
        ra     = inst[15:12];
        imm    = inst[31:16];

        known      = 1'b1;
        privileged = 1'b0;
        array      = 1'b0;
        ra_rule    = R_ZERO;
        rb_rule    = R_ZERO;
        imm_rule   = I_ZERO;

        case (opcode)
            // hlt, cli, sti, iret
            8'h00, 8'h02, 8'h03, 8'h04: begin
                privileged = 1'b1;
            end
            // nop, ret
            8'h01, 8'h32: begin
            end
            // int
            8'h85: begin
                imm_rule = I_BYTE;
            end
            // inb, outb
            8'h06, 8'h07: begin
                privileged = 1'b1;
                ra_rule    = R_REG;
                rb_rule    = R_REG;
            end
            // mov from a control register
            8'h08: begin
                privileged = 1'b1;
                ra_rule    = R_CTRL;
                rb_rule    = R_REG;
            end
            // mov to a control register
            8'h09: begin
                privileged = 1'b1;
                ra_rule    = R_REG;
                rb_rule    = R_CTRL;
            end
            // mov, add, adc, sub, sbb, cmp, and, test, or, xor, shl, shr, sar, mul, popcnt
            8'h10, 8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25, 8'h26, 8'h27, 8'h28,
            8'h2a, 8'h2b, 8'h2c, 8'h2d, 8'h2f: begin
                ra_rule = R_REG;
                rb_rule = R_REG;
            end
            // li, lih, and the immediate forms of the row above
            8'h90, 8'h91, 8'ha0, 8'ha1, 8'ha2, 8'ha3, 8'ha4, 8'ha5, 8'ha6, 8'ha7, 8'ha8,
            8'haa, 8'hab, 8'hac, 8'had: begin
                rb_rule  = R_REG;
                imm_rule = I_ANY;
            end
            // push, jmp, call, and the conditional jumps
            8'h12, 8'h30, 8'h31,
            8'h40, 8'h41, 8'h42, 8'h43, 8'h44, 8'h45, 8'h46, 8'h47, 8'h48, 8'h49: begin
                ra_rule = R_REG;
            end
            // The immediate forms of the row above
            8'h92, 8'hb0, 8'hb1,
            8'hc0, 8'hc1, 8'hc2, 8'hc3, 8'hc4, 8'hc5, 8'hc6, 8'hc7, 8'hc8, 8'hc9: begin
                imm_rule = I_ANY;
            end
            // pop, not, the conditional sets, ssat, usat
            8'h13, 8'h29,
            8'h50, 8'h51, 8'h52, 8'h53, 8'h54, 8'h55, 8'h56, 8'h57, 8'h58, 8'h59,
            8'h66, 8'h67: begin
                rb_rule = R_REG;
            end
            // mov from a register of the array
            8'h60: begin
                array   = 1'b1;
                ra_rule = R_DOT;
                rb_rule = R_REG;
            end
            // mov to a register of the array
            8'h61: begin
                array   = 1'b1;
                ra_rule = R_REG;
                rb_rule = R_DOT;
            end
            // dotv, dotm
            8'h62, 8'h63: begin
                array   = 1'b1;
                rb_rule = R_REG;
            end
            // learn, xsh
            8'h64, 8'h65: begin
                array   = 1'b1;
                ra_rule = R_REG;
            end
            // sr, srh, srb, lr, lrh, lrb, lrhu, lrbu
            8'h14, 8'h15, 8'h16, 8'h18, 8'h19, 8'h1a, 8'h1d, 8'h1e: begin
                ra_rule  = R_REG;
                rb_rule  = R_REG;
                imm_rule = I_ANY;
            end
            // dot4
            8'h2e: begin
                ra_rule  = R_REG;
                rb_rule  = R_REG;
                imm_rule = I_REG;
            end
            default: begin
                known = 1'b0;
            end
        endcase

        case (ra_rule)
            R_REG:   ra_ok = (ra < REGS);
            R_CTRL:  ra_ok = (ra < CTRLS);
            R_DOT:   ra_ok = !ra[3] && ({30'd0, ra[1:0]} < DOT_ROWS);
            default: ra_ok = (ra == 4'd0);
        endcase
        case (rb_rule)
            R_REG:   rb_ok = (rb < REGS);
            R_CTRL:  rb_ok = (rb < CTRLS);
            R_DOT:   rb_ok = !rb[3] && ({30'd0, rb[1:0]} < DOT_ROWS);
            default: rb_ok = (rb == 4'd0);
        endcase
        case (imm_rule)
            I_ANY:   imm_ok = 1'b1;
            I_REG:   imm_ok = (imm < {12'd0, REGS});
            I_BYTE:  imm_ok = (imm[15:8] == 8'd0);
            default: imm_ok = (imm == 16'd0);
        endcase

        dotm_ok = (opcode != 8'h63) || (rb <= DOTM_LAST);

        valid = known && ra_ok && rb_ok && imm_ok && dotm_ok;
    end
endmodule
