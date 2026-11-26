# The cocotb Test of the Chip

This is the test of the Tiny Tapeout template, written for Almurut II. [test.py](test.py) has a small model of the bridge, serves a program of six instructions, and checks the reset, STOP, the program, the interrupt line, and the debug port. [tb.v](tb.v) holds the chip and makes its pins wires for the test, and [Makefile](Makefile) builds it with the source files that [info.yaml](../info.yaml) lists. The platform, [asc2-project](https://github.com/toksaitov/asc2-project), has the same test in SystemVerilog and a suite that runs whole programs and the kernel on the simulated chip.

```bash
make
```

This runs the test on the hardware description and prints `TESTS=1 PASS=1 FAIL=0`. Icarus Verilog cannot read the SystemVerilog of the chip, so `sv2v` turns the files of [src/](../src) into one file of Verilog first. It needs cocotb 2.1 ([requirements.txt](requirements.txt)), Icarus Verilog 13, and `sv2v`.

```bash
make GATES=yes PDK_ROOT=...
```

This runs it on the gates, from `gate_level_netlist.v`, which the gds workflow ([gds.yaml](../.github/workflows/gds.yaml)) copies from its layout run, with the cell models of the PDK under `PDK_ROOT`. The test workflow ([test.yaml](../.github/workflows/test.yaml)) runs the first command on every push, and the gds workflow the second.
