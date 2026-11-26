![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# Almurut II

Almurut II is a 32-bit teaching computer with its own instruction set and an AI accelerator, made to teach computer organization, compilers, and operating systems. This repository is its chip for the Tiny Tapeout shuttle TTSKY26e: 16 tiles (8x2) of the SKY130 process, clocked at 12.5 MHz. The page of the chip in the datasheet, [docs/info.md](docs/info.md), tells how it works and how to test it.

The chip holds the CPU with an instruction cache, the AI accelerator, an interrupt controller, a timer, and a keyboard controller. The accelerator keeps twelve weights and twelve inputs on the chip and computes a layer of a small neural network, or a step of its training, in one instruction. A microcontroller beside the chip, the RP2350B of the Tiny Tapeout demo board, is its bridge to memory, storage, and various peripherals, over a narrow bus of the chip's own design, so the same chip can use any screen, disk, or device that the bridge supports.

## The Platform

The software and tools of Almurut II are in its platform repository, [asc2-project](https://github.com/toksaitov/asc2-project): an emulator, an assembler, a C compiler, the kernel Rach2 with its shell, utilities, and showcase programs, the firmware of the bridge for the demo board and for the bench, a version of the chip for the DE10-Lite FPGA board, and the tests. Its Readme tells how to build each part and how to run the whole computer on the demo board, with a tour of the AI accelerator, 3D graphics, and games.

## Layout

* [info.yaml](info.yaml): the project for Tiny Tapeout: the size in tiles, the clock, the top module, the source files, and the names of the pins.
* [src/](src): the hardware description in SystemVerilog, with the top module in [src/tt_um_toksaitov_almurut2.sv](src/tt_um_toksaitov_almurut2.sv), and the settings of the layout in [src/config.json](src/config.json) and [src/signoff.sdc](src/signoff.sdc).
* [docs/info.md](docs/info.md): the page of the chip in the datasheet.
* [test/](test): the cocotb test, with a small model of the bridge; [test/README.md](test/README.md) tells how to run it.
* [.github/workflows/](.github/workflows): the workflows of the Tiny Tapeout template: the layout with its precheck and the test on the gates ([gds.yaml](.github/workflows/gds.yaml)), the test ([test.yaml](.github/workflows/test.yaml)), the datasheet page ([docs.yaml](.github/workflows/docs.yaml)), and the FPGA build ([fpga.yaml](.github/workflows/fpga.yaml)).

## License

Copyright 2026 Dmitrii Toksaitov

Licensed under the [Apache License, Version 2.0](LICENSE).
