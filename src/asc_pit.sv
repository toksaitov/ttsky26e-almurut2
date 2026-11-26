// The timer (PIT) of Almurut II: it asks for an interrupt at a fixed
// pace.
//
// The timer counts down from its divisor. tick moves it by one step: the
// chip gives one tick in every 256 clocks. When the counter is at 1, the
// next tick loads the divisor again and req asks the interrupt
// controller for an interrupt, for one clock. A divisor of 0 stands for
// 65536.
//
// Ports of the CPU's port space:
//
//   0x43 write   the command: 0 makes the next data byte the high byte of
//                the divisor, 1 the low byte; after any other byte the
//                data port takes nothing
//   0x40 write   a byte of the divisor; the low byte also starts the
//                count anew from the whole divisor
//   0x40 read    the low byte of the counter (the CPU reads cnt_low)
//
// A write of the low byte in the clock of a tick takes the place of the
// tick.
module asc_pit (
    input  logic       clk,
    input  logic       rst,
    input  logic       tick,
    input  logic       io_write,
    input  logic [7:0] io_port,
    input  logic [7:0] io_wdata,
    output logic [7:0] cnt_low,
    output logic       req
);
    localparam logic [7:0] PORT_CMD  = 8'h43;
    localparam logic [7:0] PORT_DATA = 8'h40;

    typedef enum logic [1:0] {
        AWAITS_DIV_HIGH,
        AWAITS_DIV_LOW,
        AWAITS_NOTHING
    } state_t;

    state_t      state_q;
    logic [15:0] div_q;
    logic [15:0] cnt_q;

    logic        write_low;

    always_comb begin
        write_low = io_write && io_port == PORT_DATA && state_q == AWAITS_DIV_LOW;
        req       = tick && !write_low && cnt_q == 16'd1;
        cnt_low   = cnt_q[7:0];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= AWAITS_DIV_HIGH;
            div_q   <= 16'd0;
            cnt_q   <= 16'd0;
        end else begin
            if (io_write && io_port == PORT_CMD) begin
                case (io_wdata)
                    8'd0:    state_q <= AWAITS_DIV_HIGH;
                    8'd1:    state_q <= AWAITS_DIV_LOW;
                    default: state_q <= AWAITS_NOTHING;
                endcase
            end
            if (io_write && io_port == PORT_DATA && state_q == AWAITS_DIV_HIGH) begin
                div_q[15:8] <= io_wdata;
            end

            if (write_low) begin
                div_q[7:0] <= io_wdata;
                cnt_q      <= {div_q[15:8], io_wdata};
            end else if (tick) begin
                if (cnt_q == 16'd1) begin
                    cnt_q <= div_q;
                end else begin
                    cnt_q <= cnt_q - 16'd1;
                end
            end
        end
    end
endmodule
