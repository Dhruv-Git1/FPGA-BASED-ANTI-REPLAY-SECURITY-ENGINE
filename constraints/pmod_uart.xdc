## Pmod USBUART on Pmod JA, top row (bank 13, 3.3 V). Used only by the "pmod" build variant.
## The Pmod names its pins from its own FTDI chip's point of view:
##   JA2 "RXD" is data INTO the Pmod, so the FPGA transmits on it.
##   JA3 "TXD" is data OUT of the Pmod, so the FPGA receives on it.
set_property -dict { PACKAGE_PIN AA11 IOSTANDARD LVCMOS33 } [get_ports uart_tx]
set_property -dict { PACKAGE_PIN Y10  IOSTANDARD LVCMOS33 PULLUP true } [get_ports uart_rx]

## The UART input passes through a two-flip-flop synchronizer.
set_false_path -from [get_ports uart_rx]
set_false_path -to   [get_ports uart_tx]
