// Almurut II bus master, chip side, bus protocol v1
// (asc2-kb/bus-protocol-v1.md).
//
// Moved here from the bench (ab_bus there) with its names changed and
// nothing else, after it ran every bench test of protocol v1.
//
// One transaction at a time. The core presents hdr, addr and wdata,
// raises start while idle is high, and holds start, hdr, addr and wdata
// until idle goes low (the bus unit took them). It then waits for idle
// to go high again: the transaction is over, and status and rdata stay
// valid until the next start. done also pulses for one cycle at the end,
// for counters; the core must not rely on catching it, since a bad clock
// edge can make one flop miss a one-cycle pulse that another flop saw.
// rdata holds the read bytes little-endian, zero above size.
// status is the RP's code (0 OK, 1 BUS_ERROR, 2 PROTECTION, 3 MISALIGNED,
// 4 BAD_NEXT) or 5 LINK_ERROR when the link failed four times in a row.
// hdr[1:0] are ignored: bit 0 on the wire is the bus unit's sequence bit,
// bit 1 is sent as 0.
//
// Pins use Tiny Tapeout naming: uio_in, uio_out and uio_oe carry the
// bytes, req goes to uo_out[0], ack_async comes from ui_in[0] straight
// off the pad and is synchronized here. The chip top also copies uio_oe
// to uo_out[2] and frame to uo_out[3], so the RP sees who drives uio and
// whether a transaction is open.
//
// Chip-owned phase, two-phase handshake:
//
//   clk       _/~\_/~\_/~\_/~\_/~\_/~\_/~\_/~\_/~\_/~\_/~\_
//   uio_out   ==X B0 ==========================X B1 =====
//   req       ______/~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\___   one clock after the byte
//   ack pin   ____________/~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~   RP: byte taken
//   ack_s0    ____________________/~~~~~~~~~~~~~~~~~~~~~~   two flops later
//   ack_s2    ____________________________/~~~~~~~~~~~~~~   three samples agree
//
// Protection against a noisy or out-of-step link (v1):
// * ACK filter: an ACK change counts only once three synchronized samples
//   in a row agree on the new level. Pulses of one or two samples are
//   crosstalk and are counted on ack_glitch.
// * Answer check: the RP's status byte must be {SEQ, ~SEQ, 000, code 0-4}.
//   A released bus (0x00 or 0xFF) or an out-of-step RP never passes.
// * Timeout: waiting for any ACK longer than 2**TO_BITS - 1 clocks is a
//   link fault.
// * State check: the one unused state code is a link fault, so a state
//   register scrambled by a bad clock edge cannot hang the bus.
// * Open check: open_q is set when a transaction is accepted and on every
//   clock outside IDLE, and cleared only with done. IDLE while open_q is
//   set is a link fault like the unused code: a bad clock edge that tore
//   a state change into IDLE (found by the torture test, 2026-11-22:
//   SEND_TOGGLE 001 and SEND_WAIT 010 differ in two bits) would otherwise
//   leave the bus unit idle with no timeout and no done, and the core
//   waiting forever. The retry resends the same transaction, answered
//   from the RP's copy if the RP already did it.
// * After any link fault the bus unit turns uio off, stays quiet for
//   2**TO_BITS - 1 clocks (the RP's own timeout is much shorter, so the RP
//   drops back to waiting for a header and releases uio), then sends the
//   same transaction again with the same sequence bit. The RP answers a
//   repeat from its copy of the last answer, so side effects happen once.
//   After the fourth failure in a row, done comes with LINK_ERROR.
// * SEQ flips only after a transaction ends with a valid answer.
// * uio_oe is recomputed from the next state on every clock.
//
// Bus ownership: uio_oe drops one clock before the handoff toggle, and
// rises again only after the RP's handback toggle has been seen.
//
// frame (for uo_out[3]) is high from the clock the header goes out until
// the transaction ends or the bus unit gives up, and low while idle and
// quiet. It rises one clock before the header's REQ toggle, together
// with uio_oe, and falls only after the RP's last toggle has been seen,
// so every REQ change happens while frame is high. Every rise starts a
// header, a retry included. Nothing inside the chip uses it. A bridge
// may ignore it, or watch it instead of counting clocks: frame low in
// the middle of a transaction means the bus unit gave up, so the bridge
// releases uio, sets ACK to REQ's level and waits for the next header.
//
// Bench builds only: with ASC_BUS_TEST_TEAR defined, the input test_tear
// loads IDLE into the state register instead of the next state, for one
// clock, while everything else updates as usual: the torn clock edge of
// the torture test, on demand, so the open check can be shown on the
// board. The chip is built without the define; then this text adds no
// port and no logic.
module asc_bus #(
    parameter int TO_BITS = 16    // timeout and quiet time, 2**TO_BITS - 1 clocks
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    output logic        idle,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [7:0]  hdr,      // bits 1:0 unused (see above)
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0] addr,
    input  logic [31:0] wdata,
    output logic        done,
    output logic [7:0]  status,
    output logic [31:0] rdata,
    input  logic [7:0]  uio_in,
    output logic [7:0]  uio_out,
    output logic        uio_oe,
    output logic        req,
    output logic        frame,
    input  logic        ack_async,
`ifdef ASC_BUS_TEST_TEAR
    input  logic        test_tear,   // bench only, see above
`endif
    // Diagnostics for the debug port.
    output logic        ack_glitch,  // one pulse rejected by the filter
    output logic        fault,       // one pulse per link fault
    output logic [1:0]  fault_why,   // with fault: 1 timeout, 2 bad answer, 3 bad state
    output logic [15:0] dbg          // state, strobes and byte counters
);
    localparam logic [2:0] S_IDLE        = 3'd0;
    localparam logic [2:0] S_SEND_TOGGLE = 3'd1;
    localparam logic [2:0] S_SEND_WAIT   = 3'd2;
    localparam logic [2:0] S_HANDOFF     = 3'd3;
    localparam logic [2:0] S_RECV_WAIT   = 3'd4;
    localparam logic [2:0] S_RECV_TOGGLE = 3'd5;
    localparam logic [2:0] S_QUIET       = 3'd6;
    localparam logic [7:0] ST_LINK_ERROR = 8'd5;

    // Plain binary encoding, kept as written: no tool may re-encode it or
    // drop the unused code.
    (* fsm_encoding = "none", syn_encoding = "user, safe" *)
    logic [2:0]         state_q;
    logic [71:0]        tx_q;
    logic [3:0]         tx_n_q;
    logic [3:0]         tx_i_q;
    logic               write_q;
    logic [2:0]         size_q;
    logic               got_status_q;
    logic [2:0]         rx_left_q;
    logic [1:0]         rx_idx_q;
    logic               req_q;
    logic               oe_q;
    logic               frame_q;
    logic               open_q;
    logic               done_q;
    logic               fault_q;
    logic [1:0]         fault_why_q;
    logic [7:0]         out_q;
    logic [7:0]         uio_q;
    logic [7:0]         status_q;
    logic [31:0]        rdata_q;
    logic               seq_q;
    logic [1:0]         tries_q;
    logic [TO_BITS-1:0] cnt_q;
    logic               ack_meta_q;
    logic               ack_s0_q;
    logic               ack_s1_q;
    logic               ack_s2_q;
    logic               ack_s3_q;
    logic               ack_seen_q;

    logic        ack_stable;
    logic        ack_event;
    logic        stat_ok;
    logic        timeout;
    logic [2:0]  state_d;
    logic        fault_c;
    logic [1:0]  why_c;
    logic [2:0]  size_bytes;
    logic [3:0]  tx_count;
    logic [71:0] tx_vec;
    logic [7:0]  tx_byte;
    logic [7:0]  hdr_wire;

    always_comb begin
        case (hdr[5:4])
            2'b00:   size_bytes = 3'd1;
            2'b01:   size_bytes = 3'd2;
            2'b10:   size_bytes = 3'd4;
            default: size_bytes = 3'd0;
        endcase
        hdr_wire = {hdr[7:2], 1'b0, seq_q};
        tx_count = 4'd1 + (hdr[6] ? 4'd0 : 4'd4) + (hdr[7] ? {1'b0, size_bytes} : 4'd0);
        if (hdr[6]) begin
            tx_vec = {32'h00000000, wdata, hdr_wire};
        end else begin
            tx_vec = {wdata, addr, hdr_wire};
        end
        // The byte that goes out next: the header, four bytes of the
        // address unless the header says "the next word", and the bytes of
        // a write.
        tx_byte = 8'h00;
        for (int i = 0; i < 9; i++) begin
            if (tx_i_q == i[3:0]) begin
                tx_byte = tx_q[8 * i +: 8];
            end
        end
        ack_stable = (ack_s0_q == ack_s1_q) && (ack_s1_q == ack_s2_q);
        ack_event  = ack_stable && (ack_s0_q != ack_seen_q);
        // A pulse of one sample (at s1) or of two samples (at s1 and s2)
        // that went back before the filter took it.
        ack_glitch = ((ack_s2_q == ack_s0_q) && (ack_s1_q != ack_s0_q))
                  || ((ack_s3_q == ack_s0_q) && (ack_s2_q == ack_s1_q) && (ack_s1_q != ack_s0_q));
        stat_ok = (uio_q[7] == seq_q) && (uio_q[6] != seq_q) && (uio_q[5:3] == 3'b000)
               && (uio_q[2:0] <= 3'd4);
        timeout = (cnt_q == {TO_BITS{1'b1}});
    end

    always_comb begin
        state_d = state_q;
        fault_c = 1'b0;
        why_c   = 2'd0;
        case (state_q)
            S_IDLE: begin
                if (open_q) begin
                    // A transaction is open: torn into IDLE.
                    fault_c = 1'b1;
                    why_c   = 2'd3;
                    state_d = S_QUIET;
                end else if (start) begin
                    state_d = S_SEND_TOGGLE;
                end
            end
            S_SEND_TOGGLE: begin
                state_d = S_SEND_WAIT;
            end
            S_SEND_WAIT: begin
                if (ack_event) begin
                    state_d = (tx_i_q != tx_n_q) ? S_SEND_TOGGLE : S_HANDOFF;
                end else if (timeout) begin
                    fault_c = 1'b1;
                    why_c   = 2'd1;
                    state_d = S_QUIET;
                end
            end
            S_HANDOFF: begin
                state_d = S_RECV_WAIT;
            end
            S_RECV_WAIT: begin
                if (ack_event) begin
                    if (!got_status_q) begin
                        if (stat_ok) begin
                            state_d = S_RECV_TOGGLE;
                        end else begin
                            fault_c = 1'b1;
                            why_c   = 2'd2;
                            state_d = S_QUIET;
                        end
                    end else if (rx_left_q != 3'd0) begin
                        state_d = S_RECV_TOGGLE;
                    end else begin
                        state_d = S_IDLE;
                    end
                end else if (timeout) begin
                    fault_c = 1'b1;
                    why_c   = 2'd1;
                    state_d = S_QUIET;
                end
            end
            S_RECV_TOGGLE: begin
                state_d = S_RECV_WAIT;
            end
            S_QUIET: begin
                if (timeout) begin
                    state_d = (tries_q == 2'd3) ? S_IDLE : S_SEND_TOGGLE;
                end
            end
            default: begin
                fault_c = 1'b1;
                why_c   = 2'd3;
                state_d = S_QUIET;
            end
        endcase
    end

    always_ff @(posedge clk) begin
        ack_meta_q  <= ack_async;
        ack_s0_q    <= ack_meta_q;
        ack_s1_q    <= ack_s0_q;
        ack_s2_q    <= ack_s1_q;
        ack_s3_q    <= ack_s2_q;
        uio_q       <= uio_in;
        done_q      <= 1'b0;
        fault_q     <= 1'b0;
        fault_why_q <= 2'd0;
        if (rst) begin
            state_q      <= S_IDLE;
            req_q        <= 1'b0;
            oe_q         <= 1'b0;
            frame_q      <= 1'b0;
            open_q       <= 1'b0;
            ack_seen_q   <= ack_s2_q;
            seq_q        <= 1'b0;
            tries_q      <= '0;
            cnt_q        <= '0;
            tx_q         <= '0;
            tx_n_q       <= '0;
            tx_i_q       <= '0;
            write_q      <= 1'b0;
            size_q       <= '0;
            got_status_q <= 1'b0;
            rx_left_q    <= '0;
            rx_idx_q     <= '0;
            out_q        <= '0;
            status_q     <= '0;
            rdata_q      <= '0;
        end else begin
`ifdef ASC_BUS_TEST_TEAR
            state_q     <= test_tear ? S_IDLE : state_d;
`else
            state_q     <= state_d;
`endif
            oe_q        <= (state_d == S_SEND_TOGGLE) || (state_d == S_SEND_WAIT);
            frame_q     <= (state_d != S_IDLE) && (state_d != S_QUIET);
            // Cleared below in the two branches that set done_q.
            if (state_q != S_IDLE || start) begin
                open_q <= 1'b1;
            end
            fault_q     <= fault_c;
            fault_why_q <= why_c;
            // Counts clocks spent in one state: the wait for an ACK, or the
            // fixed quiet time (an ACK change does not restart the quiet).
            if (state_q == S_IDLE || state_d != state_q) begin
                cnt_q <= '0;
            end else begin
                cnt_q <= cnt_q + {{(TO_BITS - 1){1'b0}}, 1'b1};
            end
            case (state_q)
                S_IDLE: begin
                    if (start && !open_q) begin
                        tx_q    <= tx_vec;
                        tx_n_q  <= tx_count;
                        tx_i_q  <= '0;
                        out_q   <= tx_vec[7:0];
                        write_q <= hdr[7];
                        size_q  <= size_bytes;
                        rdata_q <= '0;
                        tries_q <= '0;
                    end
                end
                S_SEND_TOGGLE: begin
                    req_q  <= ~req_q;
                    tx_i_q <= tx_i_q + 4'd1;
                end
                S_SEND_WAIT: begin
                    if (ack_event) begin
                        ack_seen_q <= ack_s0_q;
                        out_q      <= tx_byte;
                    end
                end
                S_HANDOFF: begin
                    req_q        <= ~req_q;
                    got_status_q <= 1'b0;
                end
                S_RECV_WAIT: begin
                    if (ack_event) begin
                        ack_seen_q <= ack_s0_q;
                        if (!got_status_q) begin
                            if (stat_ok) begin
                                status_q     <= {5'b00000, uio_q[2:0]};
                                got_status_q <= 1'b1;
                                rx_left_q    <= (!write_q && uio_q[2:0] == 3'd0) ? size_q : 3'd0;
                                rx_idx_q     <= 2'd0;
                            end
                        end else if (rx_left_q != 3'd0) begin
                            rdata_q[{rx_idx_q, 3'b000} +: 8] <= uio_q;
                            rx_idx_q  <= rx_idx_q + 2'd1;
                            rx_left_q <= rx_left_q - 3'd1;
                        end else begin
                            done_q <= 1'b1;
                            open_q <= 1'b0;
                            seq_q  <= ~seq_q;
                        end
                    end
                end
                S_RECV_TOGGLE: begin
                    req_q <= ~req_q;
                end
                S_QUIET: begin
                    // Follow ACK while quiet, so the retry starts from
                    // where the RP's ACK has settled.
                    if (ack_stable) begin
                        ack_seen_q <= ack_s0_q;
                    end
                    if (timeout) begin
                        rdata_q <= '0;
                        if (tries_q == 2'd3) begin
                            done_q   <= 1'b1;
                            open_q   <= 1'b0;
                            status_q <= ST_LINK_ERROR;
                        end else begin
                            tries_q <= tries_q + 2'd1;
                            tx_i_q  <= '0;
                            out_q   <= tx_q[7:0];
                        end
                    end
                end
                default: begin
                end
            endcase
        end
    end

    always_comb begin
        idle      = (state_q == S_IDLE) && !open_q;
        done      = done_q;
        status    = status_q;
        rdata     = rdata_q;
        uio_out   = out_q;
        uio_oe    = oe_q;
        req       = req_q;
        frame     = frame_q;
        fault     = fault_q;
        fault_why = fault_why_q;
        dbg       = {state_q, req_q, oe_q, ack_seen_q, ack_s0_q, got_status_q,
                     tx_i_q, seq_q, rx_left_q};
    end
endmodule
