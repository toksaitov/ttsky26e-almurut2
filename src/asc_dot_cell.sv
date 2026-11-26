// One cell of the array of the dot products (see asc_dot.sv). A cell
// multiplies two signed bytes and then adds the sum of the cell on its
// left to the product.
//
// The multiplication takes eight steps, one for each bit of the factor
// b, from the top bit down. Every step doubles the sum and adds the
// factor a if the bit of b is set:
//
//   a * b = (((a * b7) * 2 + a * b6) * 2 + a * b5) * 2 + ...
//
// The top bit of a signed byte counts as -128 and not as 128, so the
// first step subtracts a where the other steps add it.
//
//   first  with step: the first step of a multiplication
//   step   one step of the multiplication
//   take   adds the sum of the left neighbor to the sum
//   start  the value that the first step starts from, a signed byte
//   half   with step: this step adds 1
//
// start and half are for the instruction learn (see asc_dot.sv). The
// seven steps after the first one double start seven times, and a 1
// that the second step adds is doubled six times, so the sum ends as
//
//   start * 128 + 64 + a * b
//
// One adder does all of it. The sum has 18 bits: enough for four
// products of two signed bytes.
module asc_dot_cell (
    input  logic        clk,
    input  logic        first,
    input  logic        step,
    input  logic        take,
    input  logic        half,
    input  logic [7:0]  start,
    input  logic [7:0]  a,
    input  logic        b_bit,
    input  logic [17:0] left,
    output logic [17:0] sum
);
    logic [17:0] sum_q;

    logic [17:0] x;
    logic [17:0] y;
    logic        subtract;
    logic        carry_in;
    logic [17:0] result;

    always_comb begin
        if (take) begin
            x        = sum_q;
            y        = left;
            subtract = 1'b0;
            carry_in = 1'b0;
        end else begin
            x        = first ? {{10{start[7]}}, start} : {sum_q[16:0], 1'b0};
            y        = b_bit ? {{10{a[7]}}, a} : 18'd0;
            subtract = first;
            carry_in = first || half;
        end

        // x - y is x + ~y + 1
        result = x + (subtract ? ~y : y) + {17'd0, carry_in};
        sum    = sum_q;
    end

    always_ff @(posedge clk) begin
        if (step || take) begin
            sum_q <= result;
        end
    end
endmodule
