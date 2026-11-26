// Almurut II on Tiny Tapeout: the top module, which gives every pin its
// job.
//
//   pin        direction  job
//   clk        in         the clock, driven by the RP2040
//   rst_n      in         the reset, low to reset, driven by the RP2040
//   uio[7:0]   both       the bytes of the bus
//   uo_out[0]  out        REQ, the strobe of the chip on the bus
//   ui_in[0]   in         ACK, the strobe of the RP2040 on the bus
//   ui_in[1]   in         IRQ, high while a device of the RP2040 asks
//   uo_out[2]  out        high while the chip drives uio
//   uo_out[3]  out        FRAME, high while a transaction is open
//   ui_in[2]   in         the clock of the debug port
//   ui_in[4]   in         the data input of the debug port
//   uo_out[1]  out        the data output of the debug port
//   ui_in[7]   in         STOP: while high, the CPU waits between two instructions
//   ui_in[5]   in         the clock line of the keyboard
//   ui_in[6]   in         the data line of the keyboard
//   ui_in[3]   in         kept free: Tiny Tapeout boards put a serial line here
//   uo_out[4]  out        kept free for the same reason; high, as a silent serial line
//   uo_out[7:5] out       free, low
//
// asc2-kb/bus-protocol-v1.md describes the bus, and asc2-kb/tt-devboard.md
// tells which pin of the RP2350 on the Tiny Tapeout board meets each of
// these.
//
// Every input except clk changes at any time. Each one goes through two
// flops in the module that uses it before anything else reads it.
//
// The chip itself is in three parts: the filters of the reset and of the
// interrupt line, the bus unit, and asc_soc with the CPU and its devices.
//
// Test builds only: with ASC_TEST_TICK defined, the module has two more
// inputs, which asc_soc.sv describes. The chip is built without the
// define.
module tt_um_toksaitov_almurut2 (
    input  logic [7:0] ui_in,
    output logic [7:0] uo_out,
    input  logic [7:0] uio_in,
    output logic [7:0] uio_out,
    output logic [7:0] uio_oe,
`ifdef ASC_TEST_TICK
    input  logic       test_tick_on,
    input  logic       test_tick,
`endif
    input  logic       ena,
    input  logic       clk,
    input  logic       rst_n
);
    logic        rst;
    logic        irq;

    logic        bus_start;
    logic        bus_idle;
    logic [7:0]  bus_hdr;
    logic [31:0] bus_addr;
    logic [31:0] bus_wdata;
    logic [7:0]  bus_status;
    logic [31:0] bus_rdata;
    logic        bus_uio_oe;
    logic        bus_req;
    logic        bus_frame;

    logic [15:0] bus_dbg;

    logic        dbg_do;

    // Outputs of the two units that nothing reads. The status has a code
    // from 0 to 5, so its upper bits are zeros.
    logic        unused_rst_raw;
    logic        unused_bus_done;
    logic        unused_bus_ack_glitch;
    logic        unused_bus_fault;
    logic [1:0]  unused_bus_fault_why;
    logic        unused_bus_status;

    // ena is high whenever the design has power, and one input is free
    logic        unused_inputs;

    asc_reset_filter reset_filter (
        .clk         (clk),
        .rst_n_async (rst_n),
        .rst         (rst),
        .rst_raw     (unused_rst_raw)
    );

    asc_irq_filter irq_filter (
        .clk       (clk),
        .irq_async (ui_in[1]),
        .irq       (irq)
    );

    asc_bus bus (
        .clk        (clk),
        .rst        (rst),
        .start      (bus_start),
        .idle       (bus_idle),
        .hdr        (bus_hdr),
        .addr       (bus_addr),
        .wdata      (bus_wdata),
        .done       (unused_bus_done),
        .status     (bus_status),
        .rdata      (bus_rdata),
        .uio_in     (uio_in),
        .uio_out    (uio_out),
        .uio_oe     (bus_uio_oe),
        .req        (bus_req),
        .frame      (bus_frame),
        .ack_async  (ui_in[0]),
        .ack_glitch (unused_bus_ack_glitch),
        .fault      (unused_bus_fault),
        .fault_why  (unused_bus_fault_why),
        .dbg        (bus_dbg)
    );

    asc_soc soc (
        .clk            (clk),
        .rst            (rst),
        .bus_start      (bus_start),
        .bus_idle       (bus_idle),
        .bus_hdr        (bus_hdr),
        .bus_addr       (bus_addr),
        .bus_wdata      (bus_wdata),
        .bus_status     (bus_status[2:0]),
        .bus_rdata      (bus_rdata),
        .bus_dbg        (bus_dbg),
        .irq_rp         (irq),
        .kbd_clk_async  (ui_in[5]),
        .kbd_data_async (ui_in[6]),
`ifdef ASC_TEST_TICK
        .test_tick_on   (test_tick_on),
        .test_tick      (test_tick),
`endif
        .stop_async     (ui_in[7]),
        .dbg_ck_async   (ui_in[2]),
        .dbg_di_async   (ui_in[4]),
        .dbg_do         (dbg_do)
    );

    always_comb begin
        uo_out            = {3'b000, 1'b1, bus_frame, bus_uio_oe, dbg_do, bus_req};
        uio_oe            = {8{bus_uio_oe}};
        unused_inputs     = &{ena, ui_in[3], 1'b0};
        unused_bus_status = &{bus_status[7:3], 1'b0};
    end
endmodule
