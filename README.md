# FPGA Anti-Replay Security Engine (ZedBoard)

SipHash-2-4 packet authentication with two replay detectors, a strict counter and a configurable sliding window, built in Verilog for the ZedBoard. The full specification is in `corrected_fpga_anti_replay_project_plan.md`.

## Quick start

```powershell
pip install -r requirements.txt
python -m pytest tests                    # Python golden models
python scripts/run_sim.py                 # all testbenches in xsim, W = 16 32 64 128
python scripts/build.py                   # four bitstreams and reports/summary.md
python scripts/build.py --program 64      # load W=64 onto the board (JTAG)
python host/demo.py --list                # find the serial port
python host/demo.py --port COM5 --w 64    # run every scenario on the board
```

Vivado 2024.2 is expected in `C:\vivado_2024\Vivado\2024.2\bin`. Set `VIVADO_BIN` to use another install.

**Board setup.** Connect a USB cable to the ZedBoard PROG port (J17) for programming. Set the boot-mode jumpers MIO2 to MIO6 to JTAG mode, which places all five on the GND side. Then choose how the PC reaches the FPGA logic.

| Variant | PC link | Build and load |
|---|---|---|
| `pmod` (default) | Digilent Pmod USBUART in the top row of Pmod JA. Pure FPGA logic. | `python scripts/build.py --w 64`, then `--program 64` |
| `ps` | The ZedBoard's own UART port (J14). Its chip is wired to the ARM processor, so a small ARM program (`sw/uart_bridge`) copies bytes to the FPGA logic. | `python scripts/build.py --variant ps --w 64`, then `--variant ps --program 64` |

Both variants use the same anti-replay logic, `rtl/top_zedboard.v`. In the `ps` variant the processor never inspects packets. The `ps` variant also needs Vitis 2024.2 for its ARM compiler and the ZedBoard board files. Set `BOARD_REPO` if they are not in the default folder.

## Context and scope

The PC sends 16-byte packets over a USB serial link. The FPGA must accept only packets that carry a valid SipHash-2-4 tag and have not been seen before. It compares two replay policies on the same traffic. The design is FPGA logic only. The Zynq ARM processor is not used.

## Goals

- Tag check that rejects any change to Device_ID, Seq_Num, Payload or tag.
- Replay state that only an authenticated packet can change.
- Strict-counter and sliding-window verdicts reported separately for every packet.
- Window size W selectable at build time (16, 32, 64, 128), with Vivado resource and timing reports for each.
- Self-checking simulation against a Python golden model, and the same checks on the board.

## Non-goals

Encryption, key provisioning, sequence-number rollover, persistent state across reset, and runtime reconfiguration. The A5 C3 reset frame and the BTNC button clear replay state for lab test sessions. Reusing old sequence numbers after a reset is insecure, and the design does not claim otherwise.

## Overview

```text
PC (host/demo.py)
  |  A5 5A + 16-byte packet, 115200 8-N-1, through Pmod USBUART on JA
  v
uart_rx --> frame_parser --> auth_stage (siphash24) --+--> strict_counter --+
                 |                                    |                     |
                 | A5 C3 or BTNC: session clear       +--> sliding_window --+
                 v                                                          v
            replay engines                             LEDs, telemetry --> uart_tx --> PC
```

**Packet.** Bytes 0 to 1 are Device_ID, 2 to 5 Seq_Num, 6 to 7 Payload, 8 to 15 MAC_Tag. Each field is sent most-significant byte first. The tag is SipHash-2-4 over bytes 0 to 7 with the lab key `00 01 .. 0f`. The tag is stored in the reference implementation's output byte order. The key equals the key of the official SipHash test vectors, so the RTL is checked against published values.

**Authentication.** `auth_stage` copies the packet into a register and starts `siphash24`. The core runs one SipRound per clock and folds each block XOR into the same clock edge. The tag is ready 10 clocks after `frame_valid`. The packet register keeps the sequence number paired with its own MAC result.

**Replay engines.** Both engines receive `auth_done`, `mac_ok` and `seq` on the same clock. Each engine updates its state only when `mac_ok` is high and its own rule accepts the packet. The strict engine accepts only `expected_seq`, which starts at 1. The sliding window keeps `initialized`, `S_max` and a W-bit mask. It reports NEW, INW (in-window), DUP, STL (stale) or AUT (authentication failed).

**Telemetry.** Each verdict produces one ASCII line, for example `SEQ=00000004 MAC=1 STR=0 WIN=1 WR=NEW LAT=000C CNT=0005`. `LAT` is the number of clocks from `frame_valid` to the verdict. Reset and parser errors produce `RST` and `ERR`. The host waits for each line before sending the next frame.

**OLED screen.** The on-board 128x32 OLED shows 4 lines of text. `oled_status.v` chooses the text and `oled_ssd1306.v` powers the screen up and redraws it continuously. For each packet the lines appear one stage at a time.

```text
RX  SEQ=00000003      frame received, with its sequence number
AUTH OK   12 CLK      tag check result, clocks from frame to verdict
STRICT: REJECT        strict counter decision
WINDOW: REPLAY!       sliding window decision: OK NEW, OK LATE, REPLAY! or TOO OLD
```

A failed tag check shows `AUTH FAILED!`, then `STRICT UNCHANGED` and `WINDOW UNCHANGED`, because neither engine's state is touched. Other screens cover boot (with a loading bar), idle (window size and packet count), session reset, frame error, and the host's final PASS or FAIL. The font is the public-domain `font8x8` set, converted by `host/gen_font.py` into `rtl/font8x8_rom.v`.

**LEDs.** `led_display.v` replays each event slowly enough to see. It only reads events and never touches replay state.

| Event | LED behaviour |
|---|---|
| Design loaded or reset | One light sweeps back and forth twice |
| Idle | LD7 heartbeat only |
| Packet checked | Lights fill in at 0.25 s per stage. LD0 received. LD1 MAC ok or LD2 MAC failed. LD3 strict accepted. LD4 window accepted, LD5 duplicate or LD6 stale. The result is then held. Rejection reasons (LD2, LD5, LD6) blink. |
| Session reset | All eight flash twice |
| Broken frame | LD0 blinks quickly |
| Host sends `A5 E1` or `A5 E0` | PASS fills the LEDs one by one, then all stay on. FAIL makes all eight blink. `demo.py` sends one of these at the end of a run. |

`python host/demo.py --port COM8 --w 64 --watch 1.5 --only normal_ooo_dup` sends one packet every 1.5 s so the stages can be followed.

## Evaluation

| Metric | Source |
|---|---|
| Functional correctness | `scripts/run_sim.py`: 256 SipHash cases, 172 replay steps with state-isolation checks, and 182 telemetry lines through the real UART path, for each W |
| LUTs, FFs, slices, per-engine breakdown | `reports/W<W>/impl_utilization*.rpt`, collected in `reports/summary.md` |
| WNS, critical path, estimated Fmax | `reports/W<W>/timing_summary.rpt` and `critical_paths.rpt`, with a 100 MHz constraint |
| Core latency | `LAT` field. Simulation shows 12 clocks for every W |
| Hardware correctness and UART round trip | `host/demo.py` output and `logs/`. On 2026-10-27 the `ps` variant with W = 64 passed every scenario on the board, with 12 clocks core latency and a 7.1 ms average PC round trip |

The 115200-baud link limits packet rate to roughly 640 frames per second before telemetry. That limit is separate from the core's clock frequency.

## Structure of changes

| Path | Contents |
|---|---|
| `rtl/` | `siphash24.v`, `auth_stage.v`, `strict_counter.v`, `sliding_window.v`, `uart_rx.v`, `uart_tx.v`, `frame_parser.v`, `telemetry.v`, `led_display.v`, `oled_status.v`, `oled_ssd1306.v`, `font8x8_rom.v`, `top_zedboard.v` |
| `constraints/` | `zedboard_base.xdc` (clock, LEDs, button, OLED) and `pmod_uart.xdc` (Pmod pins), from the Digilent ZedBoard board file |
| `rtl/top_zedboard_ps.v`, `sw/uart_bridge/` | `ps` variant: Zynq processor block plus the bare-metal ARM byte relay |
| `sim/` | `tb_siphash24.sv`, `tb_replay.sv`, `tb_top.sv`, `tb_led_display.sv`, `tb_oled.sv`, and generated `vectors/` |
| `host/` | `siphash.py`, `packet.py`, `replay_model.py`, `scenarios.py`, `telemetry.py`, `gen_vectors.py`, `demo.py` |
| `tests/` | pytest checks of the golden models |
| `scripts/` | `run_sim.py`, `build.py`, `build.tcl`, `program.tcl`, `program_ps.tcl` |
| `reports/`, `logs/` | Vivado reports and hardware run logs |

## Alternatives considered

The `ps` variant relays bytes through the ARM processor over EMIO, which needs no extra hardware. It uses a direct UART-to-UART connection, not an AXI bus. The `pmod` variant keeps the whole datapath in Verilog and is the reference for the resource comparison. A fully unrolled SipHash pipeline would accept one packet per clock but would use many times the logic. The UART delivers one packet per 1.5 ms, so the extra speed would never be used. Further reasoning is in `Decisions.md`.
