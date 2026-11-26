# The last timing report runs at the clock of the chip, 12.5 MHz. The layout
# itself aims at 20 ns (`CLOCK_PERIOD` in config.json). The delays of the
# pins stay 4 ns: 5 % of 80 ns, as they are 20 % of 20 ns.
set ::env(CLOCK_PERIOD) 80
set ::env(IO_DELAY_CONSTRAINT) 5
source $::env(SCRIPTS_DIR)/base.sdc
