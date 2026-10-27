# System flow

This file describes how data and control move through the current system.

## 1. Host side

1. `host/scenarios.py` builds lists of steps: `RESET`, `FORGED_RESET`, `REPLAY_RESET`, a `Packet`, or a `Burst` of these sent back to back.
2. `host/packet.py` builds frames. Data tags use `LAB_KEY`, reset tags use `RESET_KEY`. Tampering helpers change the payload, tag or Device_ID without fixing the tag.
3. `host/session.py` (`SessionDriver.expand`) turns each step into frames and expected lines. It assigns rising epochs to resets and runs `replay_model.AntiReplayModel` on every frame.
4. `AntiReplayModel.process` checks the tag, runs `StrictCounter.check` and `SlidingWindow.check`, picks the final verdict by policy, applies the command to the door state and updates the counters. `process_reset` accepts a reset only with a valid tag and a higher epoch.
5. `host/telemetry.py` formats the expected line. `LAT` and `CNT` are written as `????`, which `matches()` and `tb_top` treat as wildcards.

The same session driver feeds two consumers.

- `host/gen_vectors.py` writes simulation files into `sim/vectors/`, with one expected file per policy.
- `host/demo.py` sends the frames to the board and compares the replies. It takes the policy from each `RST EPOCH=... POL=` reply.

A wrong expected value can only come from `siphash.py`, `packet.py`, `replay_model.py`, `scenarios.py` or `session.py`. `tests/test_models.py` checks them against the official SipHash vectors, the specification tables and the reset rules.

## 2. FPGA datapath (`rtl/top_zedboard.v`)

All logic runs on the 100 MHz board clock. Reset comes from a 16-clock power-on counter.

The serial line reaches `top_zedboard` in one of two ways.
- `pmod` variant: straight from the Pmod USBUART pins on JA.
- `ps` variant: `rtl/top_zedboard_ps.v` wraps `top_zedboard`. The PC talks to processor UART1 on J14. The ARM program `sw/uart_bridge/main.c` copies each byte to processor UART0, which is wired to `top_zedboard` through EMIO. Replies travel back the same way.

1. **`uart_rx`** synchronizes the serial input, finds start bits and outputs bytes. A bad stop bit raises `frame_err` instead.
2. **`frame_parser`** waits for `A5`. `A5 5A` starts a data frame and `A5 C3` a reset frame. It collects 16 bytes and pulses `frame_valid` with `frame_is_reset`. A framing error or a 10 ms gap during a frame pulses `parse_err`. `A5 E1` and `A5 E0` pulse `host_pass` and `host_fail` for the displays only.
3. **`auth_stage`** copies the frame into `pkt_r` and starts **`siphash24`** with the data key or the reset key. Ten clocks later it compares the result with the received tag and pulses `auth_done` with `mac_ok`, `is_reset`, `seq` and `payload`.
4. For a reset frame the top level checks `mac_ok` and `seq > last_epoch`. If both hold it pulses `session_clear` and stores the epoch. Otherwise it pulses `reset_denied`. BTNC also pulses `session_clear`.
5. For a data frame, **`strict_counter`** and **`sliding_window`** both act on the same clock. Neither changes state when `mac_ok` is low. Both pulse `out_valid` one clock later.
6. **`decision_control`** reads SW0 through a two-flip-flop synchronizer. One clock later it pulses `decision_valid` with the final verdict, the door state after the command, and the per-engine counts.
7. The top level counts clocks from `frame_valid` to `decision_valid` as `LAT`, and decisions since power-on as `CNT`.
8. **`telemetry`** queues every decision, reset result, button press and parser error, and sends one text line per entry through **`uart_tx`**.
9. **`led_display`** and **`oled_status`** receive the same events and replay them slowly. **`oled_ssd1306`** asks `oled_status` for one character at a time, looks up each 8-pixel column in **`font8x8_rom`**, and redraws the 512-byte picture over SPI continuously.

`session_clear` clears both engines and the counters. The door state and the last epoch survive it. The displays only read events, so a display fault cannot affect a verdict.

## 3. Where errors can originate

| Symptom | Likely origin |
|---|---|
| No telemetry at all | Pmod pins swapped, wrong COM port, or the bitstream is not loaded. In the `ps` variant, also the bridge program not started (rerun `--variant ps --program`) |
| Only `ERR` lines | Baud mismatch or bytes arriving with gaps longer than 10 ms |
| `MAC=0` for every packet | Byte order differs between `packet.py` and `auth_stage.bswap64`, or the key differs |
| Every reset gives `RST DENIED` | Epoch not higher than one already used since programming, or the reset key differs |
| Correct MAC, wrong window reason | `sliding_window.v` rule, or the board was built with a different W than `--w` |
| `RES` disagrees with `STR` or `WIN` | SW0 moved during a scenario, or `decision_control.v` |
| `LOST EVENTS` line | More than 16 events queued, a burst longer than the queue |

## 4. Verification and build flow

1. `scripts/run_sim.py` runs `gen_vectors.py`, compiles `rtl/` and `sim/` with xvlog, elaborates each testbench with xelab and runs xsim.
2. `tb_siphash24` checks the core alone. `tb_replay` checks both engines and their state isolation. `tb_top` drives UART waveforms into `top_zedboard`, once with SW0 down and once up, and checks every telemetry line, including bursts and reset attacks. `tb_led_display` checks the LED patterns. `tb_oled` decodes the OLED's SPI bytes back into text and checks each screen and the power-up order.
3. `scripts/build.py` runs `scripts/build.tcl` in Vivado once per W. Reports go to `reports/W<W>/`, bitstreams to `build/W<W>/`. It then writes `reports/summary.md`.
4. `scripts/build.py --program W` runs `scripts/program.tcl` to load a bitstream over JTAG.
5. `scripts/build.py --variant ps` compiles `sw/uart_bridge` and runs `build.tcl` in `ps` mode, which generates the Zynq block design and copies `ps7_init.tcl`. `--variant ps --program W` runs `scripts/program_ps.tcl` in xsdb to load the bitstream, initialize the processor and start the bridge.
