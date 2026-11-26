// The receiver of the keyboard of Almurut II: it turns the two wires of a
// PS/2 keyboard into bytes.
//
// The keyboard drives both wires. It sends a byte as 11 bits, each one
// valid while the clock wire is low, and the receiver takes each bit when
// the clock wire falls:
//
//   kbd_clk   ~~~~\__/~~\__/~~\__/~~  ...  ~~\__/~~\__/~~~~~~
//   kbd_data  ~~\_____X_____X_____X_  ...  _X_____X~~~~~~~~~~
//                start  bit 0  bit 1        parity  stop
//
// The start bit is 0, then come the 8 bits of the byte from the lowest
// one up, a parity bit that makes the number of ones in the 9 bits odd,
// and a stop bit that is 1. valid is high for one clock with the byte on
// data when all 11 bits have come and the parity and the stop bit are
// right. A byte that fails this check is dropped.
//
// Both wires change at any time. Each one goes through two flops first.
// The clock wire then passes the three-sample filter of the bus inputs
// (asc_irq_filter.sv): a pulse of one or two samples is not a clock
// edge.
//
// A keyboard that is unplugged in the middle of a byte must not shift
// every later byte by the bits that have come. tick is high for one
// clock in every 256. If the clock wire stays still for 2**TO_BITS ticks
// inside a byte, the receiver drops the bits and waits for a start bit
// again. A keyboard clocks a bit in less than 100 microseconds.
module asc_ps2 #(
    parameter int TO_BITS = 7
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       kbd_clk_async,
    input  logic       kbd_data_async,
    input  logic       tick,
    output logic       valid,
    output logic [7:0] data
);
    localparam logic [3:0] BIT_START  = 4'd0;
    localparam logic [3:0] BIT_PARITY = 4'd9;
    localparam logic [3:0] BIT_STOP   = 4'd10;

    logic               clk_meta_q;
    logic               clk_sync_q;
    logic               clk_hist_q;
    logic               clk_hist2_q;
    logic               clk_level_q;
    logic               clk_last_q;
    logic               data_meta_q;
    logic               data_sync_q;

    logic [3:0]         bit_q;
    logic [7:0]         byte_q;
    logic               parity_q;
    logic [TO_BITS-1:0] quiet_q;
    logic               valid_q;

    logic               fall;

    always_comb begin
        fall  = clk_last_q && !clk_level_q;
        valid = valid_q;
        data  = byte_q;
    end

    // The inputs need no reset: they fill from the pins in a few clocks
    always_ff @(posedge clk) begin
        clk_meta_q  <= kbd_clk_async;
        clk_sync_q  <= clk_meta_q;
        clk_hist_q  <= clk_sync_q;
        clk_hist2_q <= clk_hist_q;
        if (clk_sync_q == clk_hist_q && clk_hist_q == clk_hist2_q) begin
            clk_level_q <= clk_sync_q;
        end
        clk_last_q  <= clk_level_q;
        data_meta_q <= kbd_data_async;
        data_sync_q <= data_meta_q;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            bit_q    <= BIT_START;
            byte_q   <= 8'd0;
            parity_q <= 1'b0;
            quiet_q  <= '0;
            valid_q  <= 1'b0;
        end else begin
            valid_q <= 1'b0;

            if (fall) begin
                quiet_q <= '0;
                case (bit_q)
                    BIT_START: begin
                        if (!data_sync_q) begin
                            bit_q <= bit_q + 4'd1;
                        end
                    end
                    BIT_PARITY: begin
                        parity_q <= data_sync_q;
                        bit_q    <= bit_q + 4'd1;
                    end
                    BIT_STOP: begin
                        valid_q <= data_sync_q && (^{byte_q, parity_q});
                        bit_q   <= BIT_START;
                    end
                    default: begin
                        byte_q <= {data_sync_q, byte_q[7:1]};
                        bit_q  <= bit_q + 4'd1;
                    end
                endcase
            end else if (bit_q != BIT_START && tick) begin
                quiet_q <= quiet_q + {{(TO_BITS - 1){1'b0}}, 1'b1};
                if (quiet_q == {TO_BITS{1'b1}}) begin
                    bit_q <= BIT_START;
                end
            end
        end
    end
endmodule
