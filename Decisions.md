# Decisions

## Use a Pmod USBUART instead of the ZedBoard's built-in UART

Date: 2026-10-25
Context: the ZedBoard's USB-UART chip connects to the Zynq ARM processor's fixed pins, not to the FPGA logic.
Decision: a Digilent Pmod USBUART on Pmod JA connects the PC straight to the FPGA logic.
Alternatives: run a bare-metal ARM program that relays bytes over an AXI bus. That needs Vitis, C code and a block design.
Trade-off: one extra adapter costs about 15 USD. Accepted because the specification describes a pure RTL datapath and this keeps it that way.

## OLED text display built in RTL

Date: 2026-10-27
Context: the project shows its decisions on the board. The ZedBoard has a 128x32 SSD1306 OLED wired to the FPGA logic.
Decision: drive it directly from RTL. `oled_ssd1306.v` uses write-only SPI at about 3 MHz, in the PmodOLED power-up order. `oled_status.v` produces 4 lines of 16 characters.
Alternatives: the Digilent PmodOLED IP needs a processor and an AXI bus. That would put software between the verdict and the display.
Trade-off: every screen is fixed in hardware. Changing the wording needs a rebuild.

## Font from font8x8, transposed at generation time

Date: 2026-10-27
Context: the OLED needs an 8x8 pixel font, and a font typed from memory would have errors.
Decision: `host/gen_font.py` converts the public-domain `font8x8_basic.h` (github.com/dhepper/font8x8) into `rtl/font8x8_rom.v`, one column byte per entry as the SSD1306 expects.
Trade-off: the ROM is generated code. Regenerate it with the script rather than editing it.

## LED display replays events slowly

Date: 2026-10-27
Context: a verdict takes 13 clocks, so LEDs that follow the datapath directly change too fast to see.
Decision: `rtl/led_display.v` latches each event and plays it back in 125 ms steps. A new event replaces the current display and restarts the step timer.
Trade-off: when packets arrive faster than the animation, the LEDs show only the latest one. Telemetry remains the complete record.

## Host result frames are display only

Date: 2026-10-27
Context: the FPGA cannot know whether a test run passed, because the expected answers live on the PC.
Decision: the PC sends `A5 E1` (pass) or `A5 E0` (fail) at the end of `demo.py`. The parser turns them into pulses that reach only `led_display`.
Trade-off: anyone on the serial link can change the LED result. They cannot change any replay state, so this is acceptable for a lab display.

## Add an ARM-relay variant for the built-in UART port

Date: 2026-10-27
Context: no Pmod USBUART was available for the first hardware test. The ZedBoard's J14 USB-UART reaches only the processor's UART1.
Decision: add a `ps` build variant. `rtl/top_zedboard_ps.v` adds the Zynq processor with the ZedBoard preset and routes UART0 to the FPGA logic through EMIO. A 40-line bare-metal program, `sw/uart_bridge/main.c`, copies bytes between UART1 and UART0.
Alternatives: wait for the Pmod, or use an AXI bus between processor and logic. AXI would change the logic's interface. A UART-to-UART relay leaves `top_zedboard` untouched.
Trade-off: the processor sits in the data path, so the system is no longer pure FPGA logic. It copies bytes and never inspects them, so every security decision still comes from the FPGA logic. The `pmod` variant remains the reference for the resource comparison.

## Bridge program without a Vitis platform

Date: 2026-10-27
Context: the bridge only needs two UARTs and a loop.
Decision: compile `sw/uart_bridge` directly with the Vitis ARM compiler, using a small start-up file and linker script. The program runs from on-chip memory. `program_ps.tcl` uses the generated `ps7_init.tcl` to set up clocks and pins.
Alternatives: a Vitis platform and board support package. That adds a large generated project for a 40-line program.

## Pmod USBUART pin direction

Date: 2026-10-25
Context: the Pmod labels JA2 as RXD and JA3 as TXD. Digilent names these from the Pmod's own FTDI chip.
Decision: the FPGA transmits on JA2 (AA11) and receives on JA3 (Y10).
Alternatives: none. A swap gives silence in both directions. If the board is silent, swapping these two lines in `constraints/pmod_uart.xdc` is the first check.

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

## Signed, epoch-checked reset (replaces the unsigned A5 C3 reset)

Date: 2026-10-27
Context: the first design reset both engines on the two bytes `A5 C3`, with no tag. A review showed the attack this allows: send packet 1, send `A5 C3`, send packet 1 again, and both engines accept it twice. The reset's log line could also be dropped, hiding the attack.
Decision: a reset is now a full 16-byte frame, `A5 C3` + body. Its Seq_Num field carries a session epoch, and its tag uses a separate reset key. `top_zedboard.v` accepts it only if the tag is valid and the epoch is higher than the last accepted epoch. Otherwise it logs `RST DENIED` and changes nothing. BTNC still resets, because it needs physical access.
Alternatives: a button-only reset is the most secure, but every automated test session would need a person at the board.
Trade-off: the last epoch is cleared at power-on, so after a power cycle an old reset frame is accepted once. A power cycle already clears all replay state, so this adds no new weakness. A session still reuses the same data key, so old packets become acceptable after any legitimate reset. That is inherent in resetting without changing keys, and the specification states it.

## Stale-packet scenario differs from the specification's literal trace

Date: 2026-10-25
Context: the specification sends 40 and then 1 in a fresh session and expects the strict engine to reject 1. In a fresh session the strict engine still expects 1, so it would accept it.
Decision: `host/scenarios.py` sends 1, then W + 8, then 1 again. Both engines then reject the final packet, as the specification's table intends.

## Telemetry event queue (replaces dropping events while busy)

Date: 2026-10-27
Context: a verdict line takes about 10 ms to send, and a frame can arrive every 1.6 ms. The first design dropped any event that arrived while a line was being sent. A review showed that this could silently hide a reset.
Decision: `telemetry.v` puts every event in a 16-entry queue and sends the lines in order. Button and parser-error events wait in a flag until the queue's write port is free. If the queue is ever full, a `LOST EVENTS` line follows.
Trade-off: about 160 extra flip-flops or LUT-RAM bits per entry. The log is now complete for bursts of up to 16 frames, which `tb_top` and `demo.py` check with back-to-back frames.

## Simulate with xsim, not Icarus Verilog

Date: 2026-10-25
Context: the installed Icarus Verilog is version 0.9.7 from 2012, with little SystemVerilog support.
Decision: all testbenches run in Vivado's xsim through `scripts/run_sim.py`. Options are passed through a file, because the Windows `.bat` wrappers split arguments at `=`.

## Build scripts use relative paths

Date: 2026-10-25
Context: the project folder name contains spaces. Vivado split an absolute path at a space and failed to find the constraints file.
Decision: `build.tcl` and `program.tcl` change into the repository root and use relative paths.

## Follow RCPROJECT.pdf where it asks for more than the plan

Date: 2026-10-27
Context: the Markdown plan allowed reporting both engine verdicts without choosing one. The group proposal, `RCPROJECT.pdf`, asks to accept or forward a packet only if authentication and the selected check pass, and to report accepted and rejected counts.
Decision: `decision_control.v` takes the policy from slide switch SW0 and produces one final verdict. Only a final accept executes the payload as a command (OPEN, CLOSE or STATUS), which drives a door state. It keeps per-engine accepted and rejected counts as four-digit BCD counters, so telemetry and the OLED print them in decimal without a divider.
Alternatives: a build-time policy setting needs a rebuild to change policy. A switch lets the demonstration show both policies live.
Trade-off: both engines still run on every packet, so the comparison is kept.

## Keep module boundaries for the measured modules

Date: 2026-10-25
Context: the first W=64 build reported 1 LUT for the strict counter. Vivado had moved its compare logic into neighbouring modules. The totals were right, but the per-engine numbers were not usable for comparison.
Decision: `top_zedboard.v` marks `u_auth`, `u_strict`, `u_window` and `u_decide` with `keep_hierarchy`.
Trade-off: Vivado can no longer merge logic across those three boundaries, so the total may grow slightly. Accepted because the per-engine cost is the quantity this project compares.

## Design without the PS7 block

Date: 2026-10-25
Context: Vivado's design-rule check warns ZPS7-1 ("PS7 block required") because the design does not instantiate the Zynq processor system.
Decision: accept the warning. The FPGA logic is configured over JTAG and clocked from the board's 100 MHz oscillator on Y9. Neither needs the processor.
