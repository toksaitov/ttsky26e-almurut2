// The arithmetic and logic unit of the Almurut II CPU. It has no
// register: the result follows the inputs.
//
//   op        result
//   ALU_ADD   x + y + carry_in
//   ALU_SUB   x - y - carry_in
//   ALU_AND   x & y
//   ALU_OR    x | y
//   ALU_XOR   x ^ y
//   ALU_LIH   the low half of y above the low half of x
//
// One adder does both the addition and the subtraction. In two's
// complement -y is ~y + 1, so x - y - carry_in is x + ~y + ~carry_in.
//
// carry is the carry out of bit 31 after an addition and the borrow after
// a subtraction. overflow is high when the result has the wrong sign for
// signed numbers: both inputs of the adder have one sign, and the sum has
// the other. Both are low after the other operations.
module asc_alu (
    input  logic [2:0]  op,
    input  logic [31:0] x,
    input  logic [31:0] y,
    input  logic        carry_in,
    output logic [31:0] result,
    output logic        carry,
    output logic        overflow
);
    localparam logic [2:0] ALU_ADD = 3'd0;
    localparam logic [2:0] ALU_SUB = 3'd1;
    localparam logic [2:0] ALU_AND = 3'd2;
    localparam logic [2:0] ALU_OR  = 3'd3;
    localparam logic [2:0] ALU_XOR = 3'd4;
    localparam logic [2:0] ALU_LIH = 3'd5;

    logic        subtract;
    logic [31:0] addend;
    logic        addend_carry;
    logic [32:0] sum;

    always_comb begin
        subtract     = (op == ALU_SUB);
        addend       = subtract ? ~y : y;
        addend_carry = subtract ? ~carry_in : carry_in;
        sum          = {1'b0, x} + {1'b0, addend} + {32'd0, addend_carry};

        carry    = 1'b0;
        overflow = 1'b0;
        case (op)
            ALU_ADD, ALU_SUB: begin
                result   = sum[31:0];
                carry    = subtract ? ~sum[32] : sum[32];
                overflow = (x[31] == addend[31]) && (sum[31] != x[31]);
            end
            ALU_AND: begin
                result = x & y;
            end
            ALU_OR: begin
                result = x | y;
            end
            ALU_XOR: begin
                result = x ^ y;
            end
            ALU_LIH: begin
                result = {y[15:0], x[15:0]};
            end
            default: begin
                result = sum[31:0];
            end
        endcase
    end
endmodule
