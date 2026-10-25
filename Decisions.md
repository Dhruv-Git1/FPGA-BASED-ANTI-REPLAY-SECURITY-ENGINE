# Decisions

## Use a Pmod USBUART instead of the ZedBoard's built-in UART

Date: 2026-10-25
Context: the ZedBoard's USB-UART chip connects to the Zynq ARM processor's fixed pins, not to the FPGA logic.
Decision: a Digilent Pmod USBUART on Pmod JA connects the PC straight to the FPGA logic.
Alternatives: run a bare-metal ARM program that relays bytes over an AXI bus. That needs Vitis, C code and a block design.
Trade-off: one extra adapter costs about 15 USD. Accepted because the specification describes a pure RTL datapath and this keeps it that way.

## Pmod USBUART pin direction

Date: 2026-10-25
Context: the Pmod labels JA2 as RXD and JA3 as TXD. Digilent names these from the Pmod's own FTDI chip.
Decision: the FPGA transmits on JA2 (AA11) and receives on JA3 (Y10).
Alternatives: none. A swap gives silence in both directions. If the board is silent, swapping these two lines in `constraints/zedboard.xdc` is the first check.

## Iterative SipHash core, one SipRound per clock

Date: 2026-10-25
Context: at 115200 baud a frame arrives at most every 1.5 ms.
Decision: `rtl/siphash24.v` reuses one SipRound circuit for all 8 rounds and finishes in 10 clocks.
Alternatives: a fully unrolled pipeline gives one tag per clock, at roughly eight times the logic.
Trade-off: lower throughput is invisible behind the UART. The simpler core also keeps the window-size comparison from being swamped by SipHash logic.

## Lab key equals the official test-vector key

Date: 2026-10-25
Context: the RTL needs a fixed key, and its output must be checked against an independent source.
Decision: key bytes are `00 01 .. 0f`. Official vector 8 (message `00 .. 07`) is the first case in `sim/vectors/siphash.hex`.
Trade-off: the key is public. That is acceptable for a lab demonstration, and the specification excludes key management.

## Reset frame A5 C3

Date: 2026-10-25
Context: the hardware demo needs many fresh test sessions without someone pressing a button each time.
Decision: the parser treats `A5 C3` as a session reset, in addition to the BTNC button.
Trade-off: anyone on the serial link can clear replay state, which reopens every old packet. This is a lab convenience only and must be removed in any real use.

## Stale-packet scenario differs from the specification's literal trace

Date: 2026-10-25
Context: the specification sends 40 and then 1 in a fresh session and expects the strict engine to reject 1. In a fresh session the strict engine still expects 1, so it would accept it.
Decision: `host/scenarios.py` sends 1, then W + 8, then 1 again. Both engines then reject the final packet, as the specification's table intends.

## Host waits for each telemetry line

Date: 2026-10-25
Context: a verdict line takes about 5 ms to send, and a new frame can arrive every 1.5 ms.
Decision: `telemetry.v` sends one line at a time and drops events that arrive while busy. `demo.py` and `tb_top.sv` wait for each line before sending more. `CNT` reveals any dropped line.
Alternatives: an event FIFO in hardware. It would add memory and logic unrelated to the comparison being measured.

## Simulate with xsim, not Icarus Verilog

Date: 2026-10-25
Context: the installed Icarus Verilog is version 0.9.7 from 2012, with little SystemVerilog support.
Decision: all testbenches run in Vivado's xsim through `scripts/run_sim.py`. Options are passed through a file, because the Windows `.bat` wrappers split arguments at `=`.

## Build scripts use relative paths

Date: 2026-10-25
Context: the project folder name contains spaces. Vivado split an absolute path at a space and failed to find the constraints file.
Decision: `build.tcl` and `program.tcl` change into the repository root and use relative paths.

## Keep module boundaries for the measured modules

Date: 2026-10-25
Context: the first W=64 build reported 1 LUT for the strict counter. Vivado had moved its compare logic into neighbouring modules. The totals were right, but the per-engine numbers were not usable for comparison.
Decision: `top_zedboard.v` marks `u_auth`, `u_strict` and `u_window` with `keep_hierarchy`.
Trade-off: Vivado can no longer merge logic across those three boundaries, so the total may grow slightly. Accepted because the per-engine cost is the quantity this project compares.

## Design without the PS7 block

Date: 2026-10-25
Context: Vivado's design-rule check warns ZPS7-1 ("PS7 block required") because the design does not instantiate the Zynq processor system.
Decision: accept the warning. The FPGA logic is configured over JTAG and clocked from the board's 100 MHz oscillator on Y9. Neither needs the processor.
