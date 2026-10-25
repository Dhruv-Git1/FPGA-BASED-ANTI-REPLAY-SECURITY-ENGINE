## ZedBoard (xc7z020clg484-1) constraints for top_zedboard.v
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

## Pmod USBUART on Pmod JA, top row (bank 13, 3.3 V).
## The Pmod names its pins from its own FTDI chip's point of view:
##   JA2 "RXD" is data INTO the Pmod, so the FPGA transmits on it.
##   JA3 "TXD" is data OUT of the Pmod, so the FPGA receives on it.
set_property -dict { PACKAGE_PIN AA11 IOSTANDARD LVCMOS33 } [get_ports uart_tx]
set_property -dict { PACKAGE_PIN Y10  IOSTANDARD LVCMOS33 PULLUP true } [get_ports uart_rx]

## The UART input and the button are asynchronous and pass through two-flip-flop
## synchronizers. LED outputs are slow status lights. None needs I/O timing.
set_false_path -from [get_ports {uart_rx btn_c}]
set_false_path -to   [get_ports {uart_tx led[*]}]
