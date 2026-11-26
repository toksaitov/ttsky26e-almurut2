// Almurut II inside its pins: the CPU, the three devices that the chip
// has of its own (the interrupt controller, the timer, and the keyboard
// controller with the receiver of the keyboard), and the debug port.
// Memory and the other devices are on the far side of the bus unit, in
// the RP2040.
//
//                    +-------+   ports   +------+
//    bus unit <----> |  CPU  | <-------> | PIT  | --+
//                    +-------+           | KBDC | --+--> PIC --> CPU
//                                        +------+   |
//    interrupt line of the RP2040 ------------------+
//
// The timer steps once in every 256 clocks.
//
// The debug port lets the RP2040 look into a chip that does not answer
// on the bus. It shows 643 bits, one at a time, on dbg_do:
//
//   bits 31:0     ip
//   bits 63:32    the instruction
//   bits 90:64    cr5, the cause of the last trap
//   bits 96:91    flags
//   bits 100:97   cr0, its bits 3 to 0
//   bits 105:101  the state of the CPU
//   bit  106      the CPU is halted
//   bit  107      the CPU has stopped after a double fault
//   bits 110:108  the status of the last transaction on the bus
//   bits 126:111  the state of the bus unit (dbg of asc_bus.sv)
//   bit  127      the CPU is between two instructions
//   bits 383:128  r0 to r7, 32 bits each
//   bits 415:384  fp
//   bits 447:416  the stack pointer of kernel mode
//   bits 479:448  lr
//   bits 511:480  cr6, the stack pointer of user mode
//   bits 543:512  cr1, the address to continue at after the last trap
//   bits 575:544  cr2, the address of the last memory fault
//   bits 607:576  cr3, the address of the top page table
//   bits 639:608  cr4, the flags before the last trap
//
//   bit  640      the port is locked
//   bit  641      bit C of cr0: the instruction cache is on
//   bit  642      bit A of cr0: programs in user mode may use the array
//                 of the dot products
//
// The bits after these read 0. The bits from 128 on leave the registers
// through a selector of their own, and the CPU does not know of it: a
// CPU that has stopped after a double fault, or halted with interrupts
// off, shows its registers as any other.
//
// The port shows what the kernel holds in its registers, so a kernel may
// lock it: it writes the value 0x4c4f434b to cr8 (asc.h). From then on
// bit 640 reads 1 and every other bit reads 0, until a reset. The lock
// hides the bits and nothing else: the bus, the clock, the reset, and
// stop work as before, and a reset opens the port again.
//
// A rise of dbg_ck with dbg_di high selects bit 0, and a rise with
// dbg_di low selects the next bit. While stop is high the CPU waits
// between two instructions, so the bits belong to one moment. The RP2040
// drives the clock of the chip, so it can lower stop for a few clocks
// and let one instruction run.
//
// Test builds only: with ASC_TEST_TICK defined, a clock with test_tick
// high steps the timer while test_tick_on is high, and the 256 clocks do
// not. A test steps the timer once per instruction this way, as the
// emulator does. The chip is built without the define; then this text
// adds no port and no logic.
module asc_soc (
    input  logic        clk,
    input  logic        rst,
    // The bus unit
    output logic        bus_start,
    input  logic        bus_idle,
    output logic [7:0]  bus_hdr,
    output logic [31:0] bus_addr,
    output logic [31:0] bus_wdata,
    input  logic [2:0]  bus_status,
    input  logic [31:0] bus_rdata,
    input  logic [15:0] bus_dbg,
    // The interrupt line of the RP2040, filtered
    input  logic        irq_rp,
    // The keyboard, straight from the pins
    input  logic        kbd_clk_async,
    input  logic        kbd_data_async,
`ifdef ASC_TEST_TICK
    input  logic        test_tick_on,
    input  logic        test_tick,
`endif
    // The debug port, straight from the pins
    input  logic        stop_async,
    input  logic        dbg_ck_async,
    input  logic        dbg_di_async,
    output logic        dbg_do
);
    localparam logic [7:0] PORT_PIC_DATA  = 8'h21;
    localparam logic [7:0] PORT_PIT_DATA  = 8'h40;
    localparam logic [7:0] PORT_KBDC_DATA = 8'h60;
    localparam logic [7:0] PORT_KBDC_STAT = 8'h64;

    logic         irq;
    logic [7:0]   irq_vec;
    logic         irq_ack;

    logic [7:0]   io_port;
    logic         io_read;
    logic         io_write;
    logic [7:0]   io_wdata;
    logic [7:0]   io_rdata;

    logic [7:0]   pic_imr;
    logic [7:0]   pit_cnt_low;
    logic         pit_req;
    logic [7:0]   kbdc_scancode;
    logic [7:0]   kbdc_status;
    logic         kbdc_req;
    logic         ps2_valid;
    logic [7:0]   ps2_data;

    logic [7:0]   prescaler_q;
    logic         tick;
    logic         pit_tick;

    logic         cpu_boundary;
    logic [107:0] cpu_dbg;
    logic [511:0] cpu_dbg_regs;
    logic         cpu_dbg_locked;
    logic [1:0]   cpu_dbg_cr0_high;
    logic [642:0] dbg_word;
    logic [9:0]   dbg_index_q;
    logic         dbg_bit;
    logic         dbg_do_q;

    // The test program watches the state of the CPU itself
    logic         unused_cpu_retired;

    // Two flops for each input that changes at any time
    logic         stop_meta_q;
    logic         stop_sync_q;
    logic         dbg_ck_meta_q;
    logic         dbg_ck_sync_q;
    logic         dbg_ck_last_q;
    logic         dbg_di_meta_q;
    logic         dbg_di_sync_q;

    asc_cpu cpu (
        .clk        (clk),
        .rst        (rst),
        .bus_start  (bus_start),
        .bus_idle   (bus_idle),
        .bus_hdr    (bus_hdr),
        .bus_addr   (bus_addr),
        .bus_wdata  (bus_wdata),
        .bus_status (bus_status),
        .bus_rdata  (bus_rdata),
        .irq        (irq),
        .irq_vec    (irq_vec),
        .irq_ack    (irq_ack),
        .io_port    (io_port),
        .io_read    (io_read),
        .io_write   (io_write),
        .io_wdata   (io_wdata),
        .io_rdata   (io_rdata),
        .stop       (stop_sync_q),
        // The start of a read of the debug port empties the cache
        .cache_flush (dbg_ck_sync_q && !dbg_ck_last_q && dbg_di_sync_q),
        .boundary   (cpu_boundary),
        .retired    (unused_cpu_retired),
        .dbg        (cpu_dbg),
        .dbg_regs   (cpu_dbg_regs),
        .dbg_locked (cpu_dbg_locked),
        .dbg_cr0_high (cpu_dbg_cr0_high)
    );

    asc_pic pic (
        .clk       (clk),
        .rst       (rst),
        .req_timer (pit_req),
        .req_kbd   (kbdc_req),
        .line_rp   (irq_rp),
        .io_write  (io_write),
        .io_port   (io_port),
        .io_wdata  (io_wdata),
        .imr       (pic_imr),
        .irq       (irq),
        .irq_vec   (irq_vec),
        .irq_ack   (irq_ack)
    );

    asc_pit pit (
        .clk      (clk),
        .rst      (rst),
        .tick     (pit_tick),
        .io_write (io_write),
        .io_port  (io_port),
        .io_wdata (io_wdata),
        .cnt_low  (pit_cnt_low),
        .req      (pit_req)
    );

    asc_kbdc kbdc (
        .clk      (clk),
        .rst      (rst),
        .rx_valid (ps2_valid),
        .rx_data  (ps2_data),
        .io_read  (io_read),
        .io_write (io_write),
        .io_port  (io_port),
        .io_wdata (io_wdata),
        .scancode (kbdc_scancode),
        .status   (kbdc_status),
        .req      (kbdc_req)
    );

    asc_ps2 ps2 (
        .clk            (clk),
        .rst            (rst),
        .kbd_clk_async  (kbd_clk_async),
        .kbd_data_async (kbd_data_async),
        .tick           (tick),
        .valid          (ps2_valid),
        .data           (ps2_data)
    );

    always_comb begin
        // What the CPU reads from a port; a port that no device has reads as zero
        case (io_port)
            PORT_PIC_DATA:  io_rdata = pic_imr;
            PORT_PIT_DATA:  io_rdata = pit_cnt_low;
            PORT_KBDC_DATA: io_rdata = kbdc_scancode;
            PORT_KBDC_STAT: io_rdata = kbdc_status;
            default:        io_rdata = 8'h00;
        endcase

        tick = (prescaler_q == 8'hff);
`ifdef ASC_TEST_TICK
        pit_tick = test_tick_on ? test_tick : tick;
`else
        pit_tick = tick;
`endif

        // An open port shows a 0 in bit 640
        dbg_word = {cpu_dbg_cr0_high, cpu_dbg_locked, cpu_dbg_regs, cpu_boundary, bus_dbg, bus_status, cpu_dbg};
        if (cpu_dbg_locked) begin
            dbg_bit = (dbg_index_q == 10'd640);
        end else begin
            dbg_bit = (dbg_index_q < 10'd643) ? dbg_word[dbg_index_q] : 1'b0;
        end
        dbg_do   = dbg_do_q;
    end

    // The inputs need no reset: they fill from the pins in two clocks
    always_ff @(posedge clk) begin
        stop_meta_q   <= stop_async;
        stop_sync_q   <= stop_meta_q;
        dbg_ck_meta_q <= dbg_ck_async;
        dbg_ck_sync_q <= dbg_ck_meta_q;
        dbg_ck_last_q <= dbg_ck_sync_q;
        dbg_di_meta_q <= dbg_di_async;
        dbg_di_sync_q <= dbg_di_meta_q;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            prescaler_q <= 8'd0;
            dbg_index_q <= 10'd0;
            dbg_do_q    <= 1'b0;
        end else begin
            prescaler_q <= prescaler_q + 8'd1;

            // The selected bit goes to its pin through a flop, so the long
            // selector is no path to a pin; the bit is at the pin four
            // clocks after a rise of dbg_ck
            dbg_do_q    <= dbg_bit;
            if (dbg_ck_sync_q && !dbg_ck_last_q) begin
                dbg_index_q <= dbg_di_sync_q ? 10'd0 : dbg_index_q + 10'd1;
            end
        end
    end
endmodule
