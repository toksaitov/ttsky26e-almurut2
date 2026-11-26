# The cocotb test of the chip, as the Tiny Tapeout template runs it: on the
# hardware description and, in the gds workflow, on the gates.
#
# A small model of the RP2040 answers the bus as asc2-kb/bus-protocol-v1.md
# describes it: the chip changes REQ for every byte it sends and for every
# byte it has taken, and the model answers each change with a change of
# ACK. The test serves a program of six instructions, one transaction after
# another, and so says for each what the chip must ask for. It checks the
# pins and not the inside of the chip:
#
#   1. During the reset the chip drives no bus pin, and the free outputs
#      have their fixed levels.
#   2. While STOP is high the CPU starts nothing, and the debug port shows
#      a CPU that waits at its reset address.
#   3. With STOP low the CPU runs on its own: it fetches from the boot ROM,
#      writes a word to RAM, lets interrupts in, and halts.
#   4. A short pulse on the interrupt line is noise. A level wakes the CPU:
#      it reads the address of the handler from the vector table and
#      fetches there.
#   5. The debug port shows ip, the instruction, the cause of the trap, the
#      flags, and cr0.
#
# It is the test of asc2-targets/tiny-tapeout/tb/tt_um_tb.sv, which
# Verilator runs, written again for cocotb and Icarus Verilog.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

CLK_PERIOD_NS = 20      # a 50 MHz clock
RP_DELAY_NS = 43        # the model answers out of step with the clock
WAIT_LIMIT = 100000     # clocks to wait for the chip before giving up
END_CLOCKS = 40         # clocks for the chip to end a transaction and run an instruction
DBG_BITS = 643

# Headers of requests without the two low bits, which the bus unit sets
HDR_FETCH = 0x2C        # a fetch of 4 bytes in kernel mode with its address
HDR_WRITE = 0xA4        # a write of 4 bytes in kernel mode
HDR_OWN_READ = 0x24     # a read of 4 bytes by the CPU itself

# The program, at the start of the boot ROM
INST_LI_R1 = 0x00FB0190  # li   r1, 0xfb   the mask that lets line 2 in
INST_LI_R2 = 0x00210290  # li   r2, 0x21   the data port of the interrupt controller
INST_OUTB = 0x00001207   # outb r1, r2
INST_SR = 0x00101014     # sr   r1, r0, 16
INST_STI = 0x00000003    # sti
INST_HLT = 0x00000000    # hlt

RESET_IP = 0x80800000
ROM_START = 0x00800000
RAM_WORD = 0x00000010    # the word that sr writes
VECTOR_WORD = 0x00000028  # vector 10: line 2 of the interrupt controller
HANDLER = 0x80800040

# Values of the debug port: flags Z, I; cr0 F, T
FLAGS_RESET = 0x02
FLAGS_HALTED = 0x12
CR0_RESET = 0x4
CR0_IN_TRAP = 0xC
CAUSE_LINE_2 = 0x000000A
CPU_AT_REST = 0          # the state between two instructions
BUS_DONE = 0             # the status of a transaction that has gone well


def field(word, high, low):
    return (word >> low) & ((1 << (high - low + 1)) - 1)


class Shown:
    """The 643 bits of the debug port. A bit can be unknown: the instruction
    register has no value before the first fetch (asc2-kb/cpu-design.md)."""

    def __init__(self, word, unknown):
        self.word = word
        self.unknown = unknown

    def field(self, high, low):
        """The bits from `high` to `low`, or -1 if any of them is unknown."""
        if field(self.unknown, high, low):
            return -1
        return field(self.word, high, low)


def value_of(signal):
    """The value of a signal as a number, or -1 while any bit is unknown."""
    value = signal.value
    return int(value) if value.is_resolvable else -1


class Bench:
    """The pins of the chip and the RP2040's side of them."""

    def __init__(self, dut):
        self.dut = dut
        self.ack = 0
        self.irq = 0
        self.dbg_ck = 0
        self.dbg_di = 0
        self.kbd_clk = 1
        self.kbd_data = 1
        self.stop = 1
        self.rp_drives = False
        self.rp_out = 0
        self.seq = 0        # the sequence bit that the next header must carry
        self.errors = []

    # The pins by their names
    def drive(self):
        self.dut.ui_in.value = (self.stop << 7 | self.kbd_data << 6 | self.kbd_clk << 5
                                | self.dbg_di << 4 | self.dbg_ck << 2 | self.irq << 1 | self.ack)
        # The board pulls a free pin up
        self.dut.uio_in.value = self.rp_out if self.rp_drives else 0xFF

    def uo(self, bit):
        value = value_of(self.dut.uo_out)
        return -1 if value < 0 else (value >> bit) & 1

    @property
    def req(self):
        return self.uo(0)

    @property
    def dbg_do(self):
        return self.uo(1)

    @property
    def chip_drives(self):
        return self.uo(2)

    @property
    def frame(self):
        return self.uo(3)

    @property
    def uio_oe(self):
        return value_of(self.dut.uio_oe)

    def check(self, ok, what):
        if not ok:
            self.dut._log.error("FAILED: %s", what)
            self.errors.append(what)

    async def clocks(self, count):
        await ClockCycles(self.dut.clk, count)

    async def check_quiet(self, count, what):
        """Watches the bus for `count` clocks, in which the chip must start nothing."""
        old_req = self.req
        quiet = True
        for _ in range(count):
            await RisingEdge(self.dut.clk)
            if self.req != old_req or self.frame != 0 or self.chip_drives != 0 or self.uio_oe != 0:
                quiet = False
        self.check(quiet, what)

    # The model of the RP2040

    async def wait_req(self):
        """Waits for the next change of REQ."""
        old_req = self.req
        waited = 0
        while self.req == old_req and waited < WAIT_LIMIT:
            await RisingEdge(self.dut.clk)
            waited += 1
        self.check(self.req != old_req, "the chip did not change REQ")
        self.check(not (self.rp_drives and self.uio_oe != 0), "the chip and the RP2040 drive the bus together")

    async def answer(self):
        await Timer(RP_DELAY_NS, unit="ns")
        self.ack ^= 1
        self.drive()

    async def take(self):
        """Takes a byte that the chip sends."""
        await self.wait_req()
        self.check(self.uio_oe == 0xFF and self.chip_drives == 1, "the chip does not drive the byte it sends")
        value = value_of(self.dut.uio_out)
        await self.answer()
        return value

    async def give(self, value):
        """Gives the chip a byte and waits until the chip has taken it."""
        self.rp_out = value
        self.rp_drives = True
        self.drive()
        await self.answer()
        await self.wait_req()

    async def serve(self, expected_hdr, expected_addr, expected_wdata, rdata, what):
        """Serves one transaction: takes the header, the address, and the
        bytes of a write, and gives the status and the bytes of a read. The
        chip must ask for what is expected; `expected_wdata` is zero for a
        read, and a write does not use `rdata`."""
        addr = 0
        wdata = 0
        hdr = await self.take()
        self.check(self.frame == 1, "FRAME is low inside a transaction")
        if hdr < 0:
            self.check(False, what + " (the header is unknown)")
            return
        size = 1 << field(hdr, 5, 4)

        # A request for "the next word" carries no address
        if not hdr & 0x40:
            for i in range(4):
                addr |= (await self.take()) << (8 * i)
        if hdr & 0x80:
            for i in range(size):
                wdata |= (await self.take()) << (8 * i)

        # The chip hands the bus over: it has stopped driving before this change of REQ
        await self.wait_req()
        self.check(self.uio_oe == 0 and self.chip_drives == 0, "the chip drives the bus after it has handed it over")

        # The status repeats the sequence bit of the header; the code 0 is "done"
        await self.give((hdr & 1) << 7 | ((~hdr) & 1) << 6)
        if not hdr & 0x80:
            for i in range(size):
                await self.give((rdata >> (8 * i)) & 0xFF)

        # The RP2040 hands the bus back
        self.rp_drives = False
        await self.answer()

        self.check((hdr & 0xFC) == expected_hdr and addr == expected_addr and wdata == expected_wdata,
                   f"{what} (header {hdr:#04x}, address {addr:#010x}, data {wdata:#010x})")

        # The sequence bit changes with every transaction that has gone well
        self.check((hdr & 3) == self.seq, "the two low bits of the header are not a zero and the sequence bit")
        self.seq ^= 1

    async def serve_read(self, expected_hdr, expected_addr, rdata, what):
        await self.serve(expected_hdr, expected_addr, 0, rdata, what)

    async def serve_write(self, expected_hdr, expected_addr, expected_wdata, what):
        await self.serve(expected_hdr, expected_addr, expected_wdata, 0, what)

    # The debug port

    async def read_debug(self):
        """Reads the bits of the debug port. A rise of its clock selects bit
        0 if its data input is high, and the next bit otherwise."""
        word = 0
        unknown = 0
        for i in range(DBG_BITS):
            self.dbg_di = 1 if i == 0 else 0
            self.drive()
            await self.clocks(4)
            self.dbg_ck = 1
            self.drive()
            await self.clocks(4)
            self.dbg_ck = 0
            self.drive()
            await self.clocks(4)
            bit = self.dbg_do
            if bit < 0:
                unknown |= 1 << i
            else:
                word |= bit << i
        return Shown(word, unknown)


@cocotb.test()
async def test_project(dut):
    bench = Bench(dut)
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())

    # 1. The reset
    dut.ena.value = 1
    dut.rst_n.value = 0
    bench.drive()
    await bench.clocks(40)
    bench.check(bench.uio_oe == 0 and bench.chip_drives == 0, "the chip drives the bus during the reset")
    bench.check(bench.req == 0 and bench.frame == 0, "REQ or FRAME is high during the reset")
    uo_out = value_of(dut.uo_out)
    bench.check(uo_out >= 0 and field(uo_out, 7, 4) == 0b0001, "the free outputs do not have their levels")
    dut.rst_n.value = 1

    # 2. STOP holds the CPU before its first instruction
    await bench.check_quiet(300, "the CPU has started a transaction while STOP is high")
    shown = await bench.read_debug()
    bench.check(shown.field(31, 0) == RESET_IP, "the debug port does not show the reset address in ip")
    bench.check(shown.field(96, 91) == FLAGS_RESET and shown.field(100, 97) == CR0_RESET,
                "the debug port does not show flags and cr0 after a reset")
    bench.check(shown.field(127, 127) == 1 and shown.field(105, 101) == CPU_AT_REST
                and shown.field(106, 106) == 0 and shown.field(107, 107) == 0,
                "the debug port does not show a CPU that waits between two instructions")
    bench.check(shown.field(642, 640) == 0,
                "the debug port does not show an open port and zeros in the upper bits of cr0 after a reset")

    # 3. The program
    bench.stop = 0
    bench.drive()
    await bench.serve_read(HDR_FETCH, ROM_START, INST_LI_R1,
                           "the first request is not a fetch at the start of the boot ROM")
    await bench.serve_read(HDR_FETCH, ROM_START + 4, INST_LI_R2,
                           "the second request is not a fetch of the second instruction")
    await bench.serve_read(HDR_FETCH, ROM_START + 8, INST_OUTB,
                           "the third request is not a fetch of the third instruction")
    await bench.serve_read(HDR_FETCH, ROM_START + 12, INST_SR,
                           "the fourth request is not a fetch of the fourth instruction")
    await bench.serve_write(HDR_WRITE, RAM_WORD, 0x000000FB, "sr does not write r1 to its word of RAM")
    await bench.serve_read(HDR_FETCH, ROM_START + 16, INST_STI,
                           "the request after the write is not a fetch of the fifth instruction")
    await bench.serve_read(HDR_FETCH, ROM_START + 20, INST_HLT,
                           "the next request is not a fetch of the sixth instruction")
    await bench.clocks(END_CLOCKS)
    await bench.check_quiet(300, "the halted CPU has started a transaction")
    bench.check(bench.uio_oe == 0 and bench.chip_drives == 0 and bench.frame == 0,
                "the bus is not released after the transactions")

    shown = await bench.read_debug()
    bench.check(shown.field(31, 0) == RESET_IP + 20 and shown.field(63, 32) == INST_HLT,
                "the debug port does not show the hlt and its address")
    bench.check(shown.field(96, 91) == FLAGS_HALTED and shown.field(100, 97) == CR0_RESET,
                "the debug port does not show flags with I set")
    bench.check(shown.field(127, 127) == 1 and shown.field(105, 101) == CPU_AT_REST
                and shown.field(106, 106) == 1 and shown.field(107, 107) == 0,
                "the debug port does not show a halted CPU")
    bench.check(shown.field(110, 108) == BUS_DONE, "the debug port does not show the status of the last transaction")

    # 4. The interrupt line. A pulse of two clocks is noise and starts nothing.
    old_req = bench.req
    bench.irq = 1
    bench.drive()
    await bench.clocks(2)
    bench.irq = 0
    bench.drive()
    await bench.clocks(200)
    bench.check(bench.req == old_req and bench.frame == 0, "a short pulse on the interrupt line has started a transaction")

    bench.irq = 1
    bench.drive()
    await bench.serve_read(HDR_OWN_READ, VECTOR_WORD, HANDLER, "the CPU does not read vector 10 for the interrupt line")
    await bench.serve_read(HDR_FETCH, HANDLER & 0x7FFFFFFF, INST_HLT,
                           "the CPU does not fetch at the address of the handler")
    await bench.clocks(END_CLOCKS)
    await bench.check_quiet(300, "the CPU has started a transaction in the handler with interrupts off")
    bench.irq = 0
    bench.drive()

    # 5. The record of the trap on the debug port
    shown = await bench.read_debug()
    bench.check(shown.field(31, 0) == HANDLER, "the debug port does not show the address of the handler in ip")
    bench.check(shown.field(90, 64) == CAUSE_LINE_2, "the debug port does not show vector 10 in cr5")
    bench.check(shown.field(96, 91) == FLAGS_RESET and shown.field(100, 97) == CR0_IN_TRAP,
                "the debug port does not show flags and cr0 inside a handler")
    bench.check(shown.field(127, 127) == 1 and shown.field(105, 101) == CPU_AT_REST
                and shown.field(106, 106) == 1 and shown.field(107, 107) == 0,
                "the debug port does not show a halted CPU in the handler")
    bench.check(shown.field(159, 128) == 0 and shown.field(191, 160) == 0xFB and shown.field(223, 192) == 0x21,
                "the debug port does not show r0, r1, and r2")
    bench.check(shown.field(543, 512) == RESET_IP + 24, "the debug port does not show the address after the hlt in cr1")
    bench.check(shown.field(639, 608) == FLAGS_HALTED, "the debug port does not show the flags before the interrupt in cr4")

    assert not bench.errors, f"{len(bench.errors)} checks failed, the first: {bench.errors[0]}"
