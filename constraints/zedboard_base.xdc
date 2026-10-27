## ZedBoard (xc7z020clg484-1) constraints shared by both build variants
## Pin locations and I/O standards come from the Digilent ZedBoard board file
## shipped with Vivado (XilinxBoardStore boards/Digilent/zedboard/1.3/part0_pins.xml).

## 100 MHz clock (GCLK)
set_property -dict { PACKAGE_PIN Y9  IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -name sys_clk -period 10.000 [get_ports clk]

## User LEDs LD0..LD7 (bank 33, 3.3 V)
set_property -dict { PACKAGE_PIN T22 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN T21 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN U22 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN U21 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]
set_property -dict { PACKAGE_PIN V22 IOSTANDARD LVCMOS33 } [get_ports {led[4]}]
set_property -dict { PACKAGE_PIN W22 IOSTANDARD LVCMOS33 } [get_ports {led[5]}]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports {led[6]}]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports {led[7]}]

## Centre push button BTNC (bank 34, powered by VADJ, 2.5 V in the board file)
set_property -dict { PACKAGE_PIN P16 IOSTANDARD LVCMOS25 } [get_ports btn_c]

## Slide switch SW0 selects the replay policy: down = strict counter, up = sliding window.
## Bank 35 is powered by VADJ, 2.5 V in the board file. A two-flip-flop synchronizer follows.
set_property -dict { PACKAGE_PIN F22 IOSTANDARD LVCMOS25 } [get_ports sw_policy]
set_false_path -from [get_ports sw_policy]

## On-board OLED (SSD1306, wired like a PmodOLED). VBAT and VDD switch power on when low.
set_property -dict { PACKAGE_PIN AA12 IOSTANDARD LVCMOS33 } [get_ports oled_sdin]
set_property -dict { PACKAGE_PIN AB12 IOSTANDARD LVCMOS33 } [get_ports oled_sclk]
set_property -dict { PACKAGE_PIN U10  IOSTANDARD LVCMOS33 } [get_ports oled_dc]
set_property -dict { PACKAGE_PIN U9   IOSTANDARD LVCMOS33 } [get_ports oled_res]
set_property -dict { PACKAGE_PIN U11  IOSTANDARD LVCMOS33 } [get_ports oled_vbat]
set_property -dict { PACKAGE_PIN U12  IOSTANDARD LVCMOS33 } [get_ports oled_vdd]
set_false_path -to [get_ports {oled_*}]

## The button is asynchronous and passes through a two-flip-flop synchronizer.
## LED outputs are slow status lights. Neither needs I/O timing.
set_false_path -from [get_ports btn_c]
set_false_path -to   [get_ports {led[*]}]
