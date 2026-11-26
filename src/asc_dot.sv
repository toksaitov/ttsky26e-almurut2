// The array of the dot products: a row of four cells, and ROWS rows of
// weights and inputs that the cells multiply, one row after another.
//
//      rows of weights and inputs        the row at work (row)
//        w0 x0   w1 x1   w2 x2                    |
//          \       |       /                      v
//           +------+------+   <-------------------+
//           |  x w  of the row at work, four bytes each
//           v
//          +------+     +------+     +------+     +------+
//    0 --> | cell | --> | cell | --> | cell | --> | cell | --> sum
//          +------+     +------+     +------+     +------+
//
// A cell (asc_dot_cell.sv) multiplies two signed bytes in eight clocks.
// The four cells multiply at the same time (step, with first in the first
// of the eight clocks). Then the sums go down the row, one cell per clock:
// take[1] makes the second cell add the sum of the first, take[2] the
// third cell the sum of the second, and take[3] the last cell the sum of
// the third. sum is the sum of the last cell.
//
// Every row has four weights and four inputs of its own, a signed byte
// each. The array has the cells once, and the CPU sends the rows through
// them one by one: row names the row whose weights and inputs the cells
// multiply. (Cells for every row did not fit the chip: three rows of four
// cells are about 12,800 um2 larger before the layout than this.)
//
// The CPU reads and writes the weights and the inputs as words, the four
// bytes of a row in a word, the first cell in the low byte: code 0 to 3
// names the weights of rows 0 to 3, and code 4 to 7 the inputs. The
// instructions of asc.h use the array in four ways:
//
//   dot4          own is low. The cells multiply the bytes of a by the
//                 bytes of a register that the CPU shifts left by one
//                 bit in each step, so every cell finds the next bit of
//                 its byte at the top of the byte: b_top holds these four
//                 bits. The weights and the inputs take no part and keep
//                 their values.
//   dotv, dotm    own is high, once for every row. Every cell multiplies
//                 its input of the row at work by its weight of that row.
//                 bit_sel names the bit of the weights for this step, 7
//                 down to 0.
//   learn         own and learn are high, once for every row. Every cell
//                 multiplies its input by the error of the row at work:
//                 err is the bit of that error for this step. A cell
//                 starts from its weight, and half is high in the second
//                 step. The sum of a cell ends as
//
//                   weight * 128 + 64 + input * error
//
//                 and store writes its bits 14 to 7 to the weight of the
//                 row at work: the weight plus the product divided by
//                 128, rounded to the nearest number. A value outside of
//                 a signed byte becomes the nearest end of the range.
//   xsh           shift moves every input on by one cell, from the first
//                 cell of the first row to the last cell of the last row,
//                 and the first cell takes the low byte of wdata.
//
// load writes wdata to the word that code names; rdata follows code.
//
// The weights and the inputs have no reset: a program writes a word
// before it reads it.
module asc_dot #(
    parameter int ROWS = 3
) (
    input  logic        clk,
    // The multiplication
    input  logic        first,
    input  logic        step,
    input  logic [3:1]  take,
    input  logic        own,
    input  logic        learn,
    input  logic        half,
    input  logic [2:0]  bit_sel,
    input  logic [31:0] a,
    input  logic [3:0]  b_top,
    input  logic        err,
    // The row at work
    input  logic [1:0]  row,
    // The weights and the inputs
    input  logic        load,
    input  logic        shift,
    input  logic        store,
    input  logic [2:0]  code,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    // The sum of the row at work
    output logic [17:0] sum
);
    localparam int CELLS = 4 * ROWS;

    logic [7:0]  w_q    [0:CELLS-1];
    logic [7:0]  x_q    [0:CELLS-1];
    logic [7:0]  w_row  [0:3];
    logic [7:0]  x_row  [0:3];
    logic [17:0] sums   [0:3];
    logic [7:0]  learnt [0:3];

    // The weights and the inputs of the row at work
    always_comb begin
        for (int k = 0; k < 4; k++) begin
            w_row[k] = 8'd0;
            x_row[k] = 8'd0;
        end
        for (int j = 0; j < ROWS; j++) begin
            if (row == 2'(j)) begin
                for (int k = 0; k < 4; k++) begin
                    w_row[k] = w_q[4 * j + k];
                    x_row[k] = x_q[4 * j + k];
                end
            end
        end
    end

    genvar r;
    genvar c;

    generate
        for (c = 0; c < 4; c++) begin : g_cell
            logic        cell_take;
            logic [7:0]  cell_a;
            logic        cell_b;
            logic [17:0] cell_left;
            logic        fits;

            always_comb begin
                cell_a = own ? x_row[c] : a[8 * c +: 8];
                if (!own) begin
                    cell_b = b_top[c];
                end else begin
                    cell_b = learn ? err : w_row[c][bit_sel];
                end

                // The first cell has no neighbor on its left
                if (c == 0) begin
                    cell_take = 1'b0;
                    cell_left = 18'd0;
                end else begin
                    cell_take = take[c];
                    cell_left = sums[c - 1];
                end

                // The bits above bit 7 of the new weight are all its sign if it fits a signed byte
                fits = (sums[c][17:14] == 4'b0000) || (sums[c][17:14] == 4'b1111);
                if (fits) begin
                    learnt[c] = sums[c][14:7];
                end else begin
                    learnt[c] = sums[c][17] ? 8'h80 : 8'h7f;
                end
            end

            asc_dot_cell u_cell (
                .clk   (clk),
                .first (first),
                .step  (step),
                .take  (cell_take),
                .half  (half),
                .start (learn ? w_row[c] : 8'd0),
                .a     (cell_a),
                .b_bit (cell_b),
                .left  (cell_left),
                .sum   (sums[c])
            );
        end

        for (r = 0; r < ROWS; r++) begin : g_row
            for (c = 0; c < 4; c++) begin : g_byte
                localparam int I = 4 * r + c;

                always_ff @(posedge clk) begin
                    if (store && row == 2'(r)) begin
                        w_q[I] <= learnt[c];
                    end else if (load && code == 3'(r)) begin
                        w_q[I] <= wdata[8 * c +: 8];
                    end

                    if (shift) begin
                        x_q[I] <= (I == 0) ? wdata[7:0] : x_q[(I == 0) ? 0 : I - 1];
                    end else if (load && code == 3'(4 + r)) begin
                        x_q[I] <= wdata[8 * c +: 8];
                    end
                end
            end
        end
    endgenerate

    always_comb begin
        rdata = 32'd0;
        sum   = sums[3];
        for (int k = 0; k < ROWS; k++) begin
            if (code == 3'(k)) begin
                rdata = {w_q[4 * k + 3], w_q[4 * k + 2], w_q[4 * k + 1], w_q[4 * k]};
            end
            if (code == 3'(4 + k)) begin
                rdata = {x_q[4 * k + 3], x_q[4 * k + 2], x_q[4 * k + 1], x_q[4 * k]};
            end
        end
    end
endmodule
