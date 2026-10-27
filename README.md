# FPGA Anti-Replay Security Engine (ZedBoard)

SipHash-2-4 packet authentication with two replay detectors, a strict counter and a configurable sliding window, built in Verilog for the ZedBoard. The group proposal is `RCPROJECT.pdf`. The detailed specification is `corrected_fpga_anti_replay_project_plan.md`.

## Quick start

```powershell
pip install -r requirements.txt
python -m pytest tests                           # Python golden models
python scripts/run_sim.py                        # all testbenches in xsim, W = 16 32 64 128, both policies
python scripts/build.py                          # four pmod bitstreams and reports/summary.md
python scripts/build.py --variant ps --w 64      # ps variant bitstream and ARM bridge
python scripts/build.py --variant ps --program 64
python host/demo.py --port COM8 --w 64           # every scenario on the board
python host/demo.py --port COM8 --w 64 --watch 3 --only normal_ooo_dup   # slow, to follow the OLED
```

Vivado 2024.2 is expected in `C:\vivado_2024\Vivado\2024.2\bin`. Set `VIVADO_BIN` to use another install.

**Board setup.** Connect USB to the PROG port (J17) for programming. Set the boot-mode jumpers MIO2 to MIO6 to JTAG mode, which places all five on the GND side. SW0 selects the replay policy: down for the strict counter (SC), up for the sliding window (SW). Then choose how the PC reaches the FPGA logic.

| Variant | PC link | Status |
|---|---|---|
| `pmod` (default) | Digilent Pmod USBUART in the top row of Pmod JA. Pure FPGA logic. | Builds and meets timing. Not yet run on hardware, because no Pmod USBUART was available. |
| `ps` | The ZedBoard's own UART port (J14). Its chip is wired to the ARM processor, so a small ARM program (`sw/uart_bridge`) copies bytes to and from the FPGA logic. | Used for every hardware run so far. |

Both variants use the same anti-replay logic, `rtl/top_zedboard.v`. In the `ps` variant the processor copies bytes and never inspects them. It also needs Vitis 2024.2 for its ARM compiler and the ZedBoard board files (set `BOARD_REPO` if they are elsewhere).

## Context and scope

The PC sends 16-byte packets over a serial link. The FPGA accepts a packet only if its SipHash-2-4 tag is valid and the selected replay policy accepts its sequence number. Both policies run on every packet, so their verdicts can be compared on identical traffic.

## Goals

- A tag check that rejects any change to Device_ID, Seq_Num, Payload or tag.
- Replay state that only an authenticated packet, or an authenticated reset, can change.
- Both engine verdicts, one final verdict under the selected policy, and accepted and rejected counts per engine.
- Window size W selectable at build time (16, 32, 64, 128), with Vivado resource and timing reports for each.
- Self-checking simulation against a Python golden model, and the same checks on the board.

## Non-goals

Encryption, key provisioning, per-device replay state, sequence-number rollover, persistent state across power cycles, and runtime reconfiguration. All devices share one replay state, so Device_ID is authenticated but does not separate senders. Both keys are public lab keys. A new session reuses the same key, so packets from an earlier session become acceptable again after a reset. This is why resets must be signed and must carry a higher epoch.

## Overview

```text
PC (host/demo.py)
  |  A5 5A + data packet, or A5 C3 + reset packet, 115200 8-N-1
  v
uart_rx -> frame_parser -> auth_stage (siphash24, data key or reset key)
             |                 |
             |                 +-- data:  strict_counter --+
             |                 |          sliding_window --+-> decision_control (SW0)
             |                 +-- reset: valid tag and epoch > last epoch -> clear session
             v
          telemetry (queued UART text), led_display, oled_status -> oled_ssd1306
```

**Frames.** A data packet holds Device_ID (bytes 0 to 1), Seq_Num (2 to 5), Payload (6 to 7) and MAC_Tag (8 to 15). Every field is sent most-significant byte first. The tag is SipHash-2-4 over bytes 0 to 7 with the data key `00 01 .. 0f`, the key of the official SipHash test vectors. A reset packet has the same layout. Its Seq_Num field carries the session epoch, and its tag uses a separate reset key `10 11 .. 1f`. A data tag can therefore never pass as a reset.

**Authentication.** `auth_stage` copies the frame into a register and runs `siphash24`, one SipRound per clock. The result is ready 10 clocks after `frame_valid`. The register keeps each result paired with its own frame.

**Replay engines.** Both engines act on the same authenticated sequence number in the same clock. Each changes state only when the tag is valid and its own rule accepts. The strict engine accepts only `expected_seq`, which starts at 1. The sliding window keeps `initialized`, `S_max` and a W-bit mask, and reports NEW, INW (in-window), DUP, STL (stale) or AUT (tag failed).

**Decision and control.** `decision_control.v` follows the PDF's Decision & Control block. The final verdict is "tag valid and the engine chosen by SW0 accepts". Only a final accept executes the payload as a command: `0001` OPEN and `0002` CLOSE set a door state, and `0003` STATUS changes nothing. The block also keeps accepted and rejected counts per engine for the current session.

**Resets.** A reset frame is accepted only with a valid reset tag and an epoch higher than the last accepted one. A forged reset and a replayed old reset are both refused with `RST DENIED`, and nothing changes. BTNC also resets, because it needs physical access.

**Telemetry.** Every event becomes one line and goes into a 16-entry queue, so bursts and resets are never silently dropped. Example:

```text
SEQ=00000004 CMD=0003 MAC=1 STR=0 WIN=1 WR=NEW POL=SW RES=ACC DOOR=C LAT=000D CNT=0003 SC=0002/0001 SW=0003/0000
RST EPOCH=6A1F3C20 POL=SW      RST DENIED      RST BUTTON      ERR
```

**OLED.** The on-board 128x32 OLED follows the PDF's mock-up. Each packet reveals one line per stage. After 3 s a summary returns with the policy, the door state and the counts.

```text
CMD: OPEN   0004      command and low 16 bits of the sequence number
AUTH: PASS            tag check
POLICY: SW S- W+      selected policy, then each engine's own answer
RESULT: ACCEPT        or RESULT: REJ AUTH / SEQ / DUP / OLD
```

Other screens show boot, signed and button resets, `RESET DENIED!`, frame errors and the final PASS or FAIL. The font comes from the public-domain `font8x8`, converted by `host/gen_font.py`.

**LEDs.** `led_display.v` shows the same events as light patterns. LD0 means received. LD1 or LD2 shows the tag result. LD3 and LD4 show the strict and window acceptance. LD5 and LD6 blink for a duplicate and a stale packet. LD7 is a heartbeat.

## Evaluation

| Metric | Source |
|---|---|
| Functional correctness | `scripts/run_sim.py`: 256 SipHash cases, 187 replay steps with state-isolation checks, and 203 telemetry lines through the UART path, for each W and both policies. `tb_oled` decodes the OLED's SPI output back into text. |
| LUTs, FFs, slices, per-module breakdown | `reports/W<W>/impl_utilization*.rpt`, collected in `reports/summary.md` |
| WNS, critical path, estimated Fmax | `reports/W<W>/timing_summary.rpt` and `critical_paths.rpt`, 100 MHz constraint |
| Core latency | `LAT`: 13 clocks from frame to final decision, the same for valid and invalid tags |
| Hardware correctness and round trip | `host/demo.py` output and `logs/` |

Each Fmax figure comes from one placement run. For W up to 64 the critical path lies in the SipHash adders, so differences between those sizes are placement noise, not an effect of W. At W = 128 the critical path moves into the window logic. The 115200-baud link limits traffic to about 640 frames per second, which is separate from the core's clock frequency.

## Structure

| Path | Contents |
|---|---|
| `rtl/` | `siphash24.v`, `auth_stage.v`, `strict_counter.v`, `sliding_window.v`, `decision_control.v`, `uart_rx.v`, `uart_tx.v`, `frame_parser.v`, `telemetry.v`, `led_display.v`, `oled_status.v`, `oled_ssd1306.v`, `font8x8_rom.v`, `top_zedboard.v`, `top_zedboard_ps.v` |
| `constraints/` | `zedboard_base.xdc` (clock, LEDs, button, SW0, OLED) and `pmod_uart.xdc` (Pmod pins) |
| `sw/uart_bridge/` | Bare-metal ARM byte relay for the `ps` variant |
| `sim/` | `tb_siphash24.sv`, `tb_replay.sv`, `tb_top.sv`, `tb_led_display.sv`, `tb_oled.sv`, generated `vectors/` |
| `host/` | `siphash.py`, `packet.py`, `replay_model.py`, `scenarios.py`, `session.py`, `telemetry.py`, `gen_vectors.py`, `gen_font.py`, `demo.py` |
| `tests/` | pytest checks of the golden models |
| `scripts/` | `run_sim.py`, `build.py`, `build.tcl`, `program.tcl`, `program_ps.tcl` |
| `reports/`, `logs/` | Vivado reports and hardware run logs |

## Alternatives considered

An unsigned reset is simpler, but anyone on the link could wipe replay state and replay old packets. A button-only reset is secure but prevents automated test sessions. The signed, epoch-checked reset keeps automation and refuses forged and replayed resets. A fully unrolled SipHash pipeline would accept one packet per clock but would use several times the logic, and the UART delivers one packet per 1.5 ms. The `ps` variant relays bytes over EMIO, a direct UART-to-UART connection, so `top_zedboard.v` is identical in both variants. Further reasoning is in `Decisions.md`.
