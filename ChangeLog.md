# ChangeLog

## 2026-10-27

### rtl/frame_parser.v, rtl/auth_stage.v, rtl/siphash24.v, rtl/top_zedboard.v
Replaced the unsigned `A5 C3` reset with a signed reset frame. It carries a session epoch and a tag made with a separate reset key. The FPGA accepts it only with a valid tag and a higher epoch, otherwise it logs `RST DENIED` and changes nothing. SipHash now takes its key as an input.
Reason: a review showed that the unsigned reset let anyone wipe replay state and replay an old packet, and that the reset's log line could be dropped.

### rtl/telemetry.v
Events now go into a 16-entry queue, so no reset or verdict line is dropped while another line is being sent. Verdict lines add CMD, POL, RES, DOOR and per-engine accepted/rejected counts.

### rtl/decision_control.v (new), constraints/zedboard_base.xdc, rtl/top_zedboard_ps.v
Added the Decision & Control block from RCPROJECT.pdf. Slide switch SW0 selects the policy, the block produces one final verdict, executes OPEN and CLOSE commands only on a final accept, and counts accepted and rejected packets per engine. Added the SW0 pin.
Impact: core latency is 13 clocks from frame to final decision, one more than before.

### rtl/oled_status.v, sim/tb_oled.sv
OLED screens now follow the PDF layout (CMD, AUTH, POLICY, RESULT), with a summary screen for counts and door state and screens for signed, button and denied resets.

### host/packet.py, host/replay_model.py, host/scenarios.py, host/session.py (new), host/telemetry.py, host/gen_vectors.py, host/demo.py, tests/test_models.py
The golden model gains the policy, final verdict, door, counters and reset rules. New scenarios cover a replayed OPEN command, forged and replayed resets, a back-to-back burst and Device_ID tampering. `session.py` turns steps into frames and expected lines for both simulation and the demo. Simulation expectations are written per policy. 35 Python tests pass.

### sim/tb_top.sv, scripts/run_sim.py, scripts/build.py
`tb_top` runs with SW0 down and up and treats `?` in expected lines as a wildcard. All 15 simulations pass for W = 16, 32, 64 and 128. `reports/summary.md` gains a critical-path location column and the decision block's size.

### README.md, Flow.md, Decisions.md
Rewrote the README for the new design and stated plainly that only the `ps` variant has run on hardware. Recorded the signed reset, the queue and the PDF-driven decision block, and fixed a stale file name.

### rtl/oled_status.v, rtl/oled_ssd1306.v, rtl/font8x8_rom.v, host/gen_font.py, sim/tb_oled.sv
Added the on-board OLED display. It shows boot, idle, each packet's stages, reset, frame errors and the final PASS or FAIL as text.
`tb_oled` decodes the SPI output back into text and caught two bugs before hardware. A one-bit shift came from the testbench decoder. A skipped first pixel column came from the driver.

### rtl/top_zedboard.v, rtl/top_zedboard_ps.v, constraints/zedboard_base.xdc, scripts/run_sim.py
Connected the OLED in both top levels and added its six pins.

### rtl/led_display.v, rtl/top_zedboard.v, rtl/frame_parser.v, sim/tb_led_display.sv, scripts/run_sim.py
Added an LED display that replays each event slowly enough to see. It covers the boot sweep, stage-by-stage verdicts, blinking rejection reasons, reset flash, parse errors and an overall PASS or FAIL. The parser accepts the display-only frames `A5 E1` and `A5 E0`. The `HEARTBEAT_BIT` parameter is replaced by `LED_TICK_CYCLES`.
Impact: LED meanings changed from fixed status bits to the patterns in README.md. Replay logic and telemetry are unchanged.

### host/packet.py, host/demo.py
Added `PASS_FRAME` and `FAIL_FRAME`. `demo.py` sends one at the end of a run, and gains `--watch SECONDS` and `--only SCENARIO`.

### rtl/top_zedboard_ps.v, sw/uart_bridge/, scripts/build.tcl, scripts/build.py, scripts/program_ps.tcl
Added the `ps` build variant. The PC uses the ZedBoard's J14 UART, and an ARM program relays bytes to the unchanged anti-replay logic through EMIO.
Impact: the board can be tested without a Pmod USBUART. `build.tcl` takes a second argument, `pmod` or `ps`.

### constraints/zedboard_base.xdc, constraints/pmod_uart.xdc
Split `zedboard.xdc` so the Pmod UART pins live in their own file. Only the `pmod` variant reads it.

### logs/demo_W64_20261027_151708.log
First hardware run, `ps` variant with W = 64. Every scenario passed, with 12 clocks core latency and a 7.1 ms average round trip.

### README.md, Flow.md, Decisions.md
Described the two variants and recorded the reasons for the ARM relay.

## 2026-10-25

### Repository setup
Created the FPGA layout: `rtl/`, `sim/`, `constraints/`, `scripts/`, `host/`, `tests/`, `reports/`, `logs/`. Added `README.md`, `Flow.md`, `Decisions.md`, `requirements.txt` and `.gitignore`.
Moved the repo-conventions skill into `.claude/skills/` so it sits outside the project code.

### host/siphash.py, host/packet.py, host/replay_model.py, host/scenarios.py, host/telemetry.py, tests/test_models.py
Added the Python golden models and test scenarios. They are checked against the 16 official SipHash-2-4 vectors and the specification's replay tables. 28 tests pass.

### host/gen_vectors.py, sim/tb_siphash24.sv, sim/tb_replay.sv, sim/tb_top.sv, scripts/run_sim.py
Added vector generation and self-checking testbenches run in xsim. All pass for W = 16, 32, 64 and 128. Core latency is 12 clocks from `frame_valid` to the verdict.

### rtl/*.v
Added the SipHash-2-4 core, authentication stage, strict counter, sliding window, UART receiver and transmitter, frame parser, telemetry and ZedBoard top level.

### constraints/zedboard.xdc, scripts/build.tcl, scripts/program.tcl, scripts/build.py
Added the board constraints, the Vivado non-project build, JTAG programming and the report summary.
Fixed a build failure. Vivado split the absolute constraints path at the spaces in the folder name, so the Tcl scripts now use relative paths.

### rtl/top_zedboard.v, scripts/build.py
Marked the authentication stage and both replay engines with keep_hierarchy, so the utilization report gives a true per-engine cost.
Moved the Vivado -log and -journal options before -tclargs. They were being passed to the Tcl script instead.

### host/demo.py
Added the hardware demo that sends every scenario to the board and checks each telemetry line.

### reports/W16, reports/W32, reports/W64, reports/W128, reports/summary.md
Built all four window sizes with keep_hierarchy. Every build meets the 100 MHz constraint. The sliding window's LUT count roughly doubles with each doubling of W. At W = 128 the critical path moves from the SipHash core into the window logic.
