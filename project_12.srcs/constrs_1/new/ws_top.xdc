# Clock input (e.g. 100 MHz on a Xilinx board)
set_property PACKAGE_PIN W5        [get_ports clk]
set_property IOSTANDARD LVCMOS33   [get_ports clk]
create_clock -name sys_clk -period 10.000 [get_ports clk]

# Reset button
set_property PACKAGE_PIN V17       [get_ports rst]
set_property IOSTANDARD LVCMOS33   [get_ports rst]

# Start button / switch
set_property PACKAGE_PIN U18       [get_ports start]
set_property IOSTANDARD LVCMOS33   [get_ports start]

# Done LED
set_property PACKAGE_PIN U16       [get_ports done_led]
set_property IOSTANDARD LVCMOS33   [get_ports done_led]
