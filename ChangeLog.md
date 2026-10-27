# ChangeLog

## 2026-10-27

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
