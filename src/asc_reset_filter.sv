// Almurut II reset input, chip side.
//
// RST_N comes from the RP (rst_n on the Tiny Tapeout devkit) and is
// asynchronous to clk. It passes through a two-flop synchronizer, then a
// filter: rst takes the synchronized level only after that level has held
// for 8 clocks in a row. The RP holds a reset for milliseconds; a shorter
// pulse is crosstalk on the wire and is ignored. On the Test 3 bench such
// pulses reset the chip side hundreds of times per run at 12.5 MHz and
// above; the bench now counts them with rst_raw.
//
// The filter keeps the last seven samples next to the newest one and needs
// no counter. No register has a reset or an initial value: at power-up the
// RP holds RST_N low, and after ten clocks every sample is a known one and
// rst is high, whatever the registers held. A counter would do with fewer
// flops, but a simulator that starts every flop as unknown never gets a
// known value out of a counter that nothing resets.
module asc_reset_filter (
    input  logic clk,
    input  logic rst_n_async,
    output logic rst,      // filtered, active high, synchronous to clk
    output logic rst_raw   // synchronized only, for diagnostics
);
    logic       meta_q;
    logic       sync_q;
    logic [6:0] past_q;
    logic       rst_q;

    always_ff @(posedge clk) begin
        meta_q <= ~rst_n_async;
        sync_q <= meta_q;
        past_q <= {past_q[5:0], sync_q};
        if (&{past_q, sync_q}) begin
            rst_q <= 1'b1;
        end else if (~|{past_q, sync_q}) begin
            rst_q <= 1'b0;
        end
    end

    always_comb begin
        rst     = rst_q;
        rst_raw = sync_q;
    end
endmodule
