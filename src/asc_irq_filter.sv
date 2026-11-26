// Almurut II interrupt input, chip side.
//
// IRQ comes from the RP (ui_in[1] on the Tiny Tapeout devkit) as a level,
// high while an interrupt is pending, and is asynchronous to clk. It
// passes through a two-flop synchronizer and the same three-sample filter
// as ACK in asc_bus: irq takes a new level only when three synchronized
// samples in a row agree on it, so a crosstalk pulse one or two samples
// long never raises or drops it. A new level reaches irq five clocks
// after it reaches the pin's first flop, nothing next to a level the RP
// holds until the CPU acknowledges it.
//
// Moved here from the bench (ab_irq there) with its name changed and
// nothing else, after it ran every bench test of protocol v1.
//
// No reset: the flops fill from the pin within four clocks, well inside
// the 8 clocks of asc_reset_filter.
module asc_irq_filter (
    input  logic clk,
    input  logic irq_async,
    output logic irq
);
    logic meta_q;
    logic sync_q;
    logic hist_q;
    logic hist2_q;
    logic irq_q;

    always_ff @(posedge clk) begin
        meta_q  <= irq_async;
        sync_q  <= meta_q;
        hist_q  <= sync_q;
        hist2_q <= hist_q;
        if (sync_q == hist_q && hist_q == hist2_q) begin
            irq_q <= sync_q;
        end
    end

    always_comb begin
        irq = irq_q;
    end
endmodule
