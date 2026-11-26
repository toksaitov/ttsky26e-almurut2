// The keyboard controller (KBDC) of Almurut II: it holds the last byte
// that the keyboard has sent until the CPU reads it.
//
// rx_valid comes from the receiver of the keyboard's two wires
// (asc_ps2.sv) for one clock with a byte on rx_data. The controller keeps
// the byte, sets W, and asks the interrupt controller for an interrupt
// with req, for one clock.
//
// Ports of the CPU's port space:
//
//   0x60 read    the byte (the CPU reads scancode); io_read with this
//                port clears W
//   0x64 read    the status (the CPU reads status)
//   0x64 write   a byte with bit 1 set clears O
//
// The status:
//
//   bit 0  W (waiting)  a byte has come and has not been read
//   bit 1  O (overrun)  a byte has taken the place of one that was not
//                       read
//
// Two events in one clock are settled so that nothing is lost. A byte
// that comes while the CPU reads the data port: the CPU gets the old
// byte, and the new one waits. A byte that is lost while the CPU clears
// O: O stays set.
module asc_kbdc (
    input  logic       clk,
    input  logic       rst,
    input  logic       rx_valid,
    input  logic [7:0] rx_data,
    input  logic       io_read,
    input  logic       io_write,
    input  logic [7:0] io_port,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [7:0] io_wdata,  // only bit 1 means something to this device
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [7:0] scancode,
    output logic [7:0] status,
    output logic       req
);
    localparam logic [7:0] PORT_DATA = 8'h60;
    localparam logic [7:0] PORT_STAT = 8'h64;

    logic [7:0] scancode_q;
    logic       waiting_q;
    logic       overrun_q;

    logic       read_data;
    logic       clear_overrun;

    always_comb begin
        read_data     = io_read && io_port == PORT_DATA;
        clear_overrun = io_write && io_port == PORT_STAT && io_wdata[1];

        scancode = scancode_q;
        status   = {6'd0, overrun_q, waiting_q};
        req      = rx_valid;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            scancode_q <= 8'd0;
            waiting_q  <= 1'b0;
            overrun_q  <= 1'b0;
        end else begin
            if (read_data) begin
                waiting_q <= 1'b0;
            end
            if (clear_overrun) begin
                overrun_q <= 1'b0;
            end
            if (rx_valid) begin
                scancode_q <= rx_data;
                waiting_q  <= 1'b1;
                if (waiting_q && !read_data) begin
                    overrun_q <= 1'b1;
                end
            end
        end
    end
endmodule
