# The cocotb test of the chip, as the Tiny Tapeout template runs it.
# See https://docs.cocotb.org/en/stable/quickstart.html for more info.
#
# `make` runs the test on the hardware description, `make GATES=yes` on the
# gate netlist that the gds workflow copies to gate_level_netlist.v.

# defaults
SIM ?= icarus
FST ?= -fst # Use more efficient FST format
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../src

# The sources in the order of info.yaml
PROJECT_SOURCES = $(shell sed -n 's/^ *- "\(.*\.sv\)"$$/\1/p' ../info.yaml)

ifneq ($(GATES),yes)

# RTL simulation. Icarus Verilog cannot read the SystemVerilog of the chip,
# so sv2v turns it into one file of Verilog first.
SIM_BUILD				= sim_build/rtl
CHIP_VERILOG    = $(PWD)/$(SIM_BUILD)/chip.v
VERILOG_SOURCES += $(CHIP_VERILOG)

else

# Gate level simulation:
SIM_BUILD				= sim_build/gl
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DUSE_POWER_PINS
COMPILE_ARGS    += -DSIM
COMPILE_ARGS    += -DUNIT_DELAY=\#1
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v

# this gets copied in by the GDS action workflow
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v

endif

COMPILE_ARGS 		+= -g2012

# Include the testbench sources:
VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb

# List test modules to run, separated by commas and without the .py suffix:
COCOTB_TEST_MODULES = test

# include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim

# After the include, so that cocotb's rule stays the first one
ifneq ($(GATES),yes)
$(CHIP_VERILOG): $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES)) ../info.yaml
	@mkdir -p $(dir $@)
	sv2v $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES)) > $@
endif
