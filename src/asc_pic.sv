// The interrupt controller (PIC) of Almurut II: it collects the requests
// of the devices and tells the CPU which one to serve.
//
//   line 0   the timer; a request is one pulse and is kept until served
//   line 1   the keyboard controller; the same
//   line 2   the devices of the RP2040; a level, held by the RP2040 until
//            the kernel has served its device
//
// A request waits in irr_q whatever the mask says, so a request that
// comes while its line is masked is served once the line is open. The
// lowest waiting line that is not masked wins. irq tells the CPU that
// there is one, and irq_vec is its vector: the offset plus the number of
// the line.
//
// The CPU answers with irq_ack in the clock in which it takes the
// interrupt. The request of the winning line is then forgotten; a new
// request of the same line in that very clock stays.
//
// Ports of the CPU's port space:
//
//   0x20 write   the command: 0 makes the next data byte the mask, 1 the
//                offset of the vectors; after any other byte the data
//                port takes nothing
//   0x21 write   the mask (a set bit closes a line) or the offset
//   0x21 read    the mask (the CPU reads imr)
module asc_pic (
    input  logic       clk,
    input  logic       rst,
    input  logic       req_timer,
    input  logic       req_kbd,
    input  logic       line_rp,
    input  logic       io_write,
    input  logic [7:0] io_port,
    input  logic [7:0] io_wdata,
    output logic [7:0] imr,
    output logic       irq,
    output logic [7:0] irq_vec,
    input  logic       irq_ack
);
    localparam logic [7:0] PORT_CMD  = 8'h20;
    localparam logic [7:0] PORT_DATA = 8'h21;

    localparam logic [7:0] RESET_VEC_OFF = 8'd8;  // the vectors below belong to the exceptions of the CPU

    typedef enum logic [1:0] {
        AWAITS_IMR,
        AWAITS_VEC_OFF,
        AWAITS_NOTHING
    } state_t;

    state_t     state_q;
    logic [7:0] imr_q;
    logic [7:0] vec_off_q;
    logic [1:0] irr_q;

    logic [2:0] open;
    logic [1:0] line;

    always_comb begin
        open = {line_rp, irr_q} & ~imr_q[2:0];
        irq  = |open;

        if (open[0]) begin
            line = 2'd0;
        end else if (open[1]) begin
            line = 2'd1;
        end else begin
            line = 2'd2;
        end

        irq_vec = vec_off_q + {6'd0, line};
        imr     = imr_q;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q   <= AWAITS_IMR;
            imr_q     <= 8'hff;
            vec_off_q <= RESET_VEC_OFF;
            irr_q     <= 2'b00;
        end else begin
            if (irq_ack && line == 2'd0) begin
                irr_q[0] <= 1'b0;
            end
            if (irq_ack && line == 2'd1) begin
                irr_q[1] <= 1'b0;
            end
            if (req_timer) begin
                irr_q[0] <= 1'b1;
            end
            if (req_kbd) begin
                irr_q[1] <= 1'b1;
            end

            if (io_write && io_port == PORT_CMD) begin
                case (io_wdata)
                    8'd0:    state_q <= AWAITS_IMR;
                    8'd1:    state_q <= AWAITS_VEC_OFF;
                    default: state_q <= AWAITS_NOTHING;
                endcase
            end
            if (io_write && io_port == PORT_DATA) begin
                case (state_q)
                    AWAITS_IMR:     imr_q     <= io_wdata;
                    AWAITS_VEC_OFF: vec_off_q <= io_wdata;
                    default: begin
                    end
                endcase
            end
        end
    end
endmodule
