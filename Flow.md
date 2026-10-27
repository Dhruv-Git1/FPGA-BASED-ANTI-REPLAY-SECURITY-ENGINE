# System flow

This file describes how data and control move through the current system.

## 1. Host side

1. `host/scenarios.py` builds lists of steps. A step is either `"reset"` or a `Packet`.
2. `host/packet.py` builds each packet. It calls `siphash.siphash24` over bytes 0 to 7 to make the tag. Tampering helpers change fields without fixing the tag.
3. `host/replay_model.py` (`AntiReplayModel.process`) decides the expected verdict. It checks the tag, then runs `StrictCounter.check` and `SlidingWindow.check` on the same result.
4. `host/telemetry.py` turns a verdict into the expected text prefix.

The same three modules feed two consumers.

- `host/gen_vectors.py` writes files for simulation into `sim/vectors/`.
- `host/demo.py` sends frames to the board and compares the returned lines.

A wrong expected value can only come from `siphash.py`, `replay_model.py` or `scenarios.py`. `tests/test_models.py` checks these against the official SipHash vectors and the specification tables.

## 2. FPGA datapath (`rtl/top_zedboard.v`)

All logic runs on the 100 MHz board clock. Reset comes from a 16-clock power-on counter.

The serial line reaches `top_zedboard` in one of two ways.
- `pmod` variant: straight from the Pmod USBUART pins on JA.
- `ps` variant: `rtl/top_zedboard_ps.v` wraps `top_zedboard`. The PC talks to processor UART1 on J14. The ARM program `sw/uart_bridge/main.c` copies each byte to processor UART0, which is wired to `top_zedboard` through EMIO. Replies travel back the same way.

1. **`uart_rx`** synchronizes the serial input, finds start bits and outputs bytes. A bad stop bit raises `frame_err` instead.
2. **`frame_parser`** waits for `A5`. `A5 5A` begins a frame. It collects 16 bytes and pulses `frame_valid`. `A5 C3` pulses `reset_req`. A framing error or a 10 ms gap during a frame pulses `parse_err`.
3. **`auth_stage`** copies the frame into `pkt_r` and starts **`siphash24`**. Ten clocks later it compares the result with the received tag. It then pulses `auth_done` with `mac_ok` and `seq`.
4. **`strict_counter`** and **`sliding_window`** both act on `auth_done` in the same clock. Neither engine changes state when `mac_ok` is low. Both pulse `out_valid` one clock later.
5. The top level counts clocks from `frame_valid` to the verdict as `LAT`. It also counts verdicts as `CNT`.
6. **`telemetry`** copies the verdict and sends one text line through **`uart_tx`**. `reset_req`, the BTNC button and `parse_err` produce `RST` or `ERR` lines.
7. **`led_display`** receives the same verdict and plays it back as a stage-by-stage light pattern. It also shows the boot sweep, `session_clear`, `parse_err`, and the host's `A5 E1` or `A5 E0` result frames, which the parser reports as `host_pass` and `host_fail`.

8. **`oled_status`** receives the same events and keeps the text for 4 screen lines. **`oled_ssd1306`** asks it for one character at a time, looks up each 8-pixel column in **`font8x8_rom`**, and sends the bytes to the screen over SPI. It redraws the full 512-byte picture continuously.

`session_clear` (the A5 C3 frame or the BTNC button) clears both engines. The LED display only reads events, so an LED fault cannot affect a verdict.

## 3. Where errors can originate

| Symptom | Likely origin |
|---|---|
| No telemetry at all | Pmod pins swapped, wrong COM port, or the bitstream is not loaded. In the `ps` variant, also the bridge program not started (rerun `--variant ps --program`) |
| Only `ERR` lines | Baud mismatch or bytes arriving with gaps longer than 10 ms |
| `MAC=0` for every packet | Byte order differs between `packet.py` and `auth_stage.bswap64`, or the key differs |
| Correct MAC, wrong window reason | `sliding_window.v` rule, or the board was built with a different W than `--w` |
| Missing lines, CNT jumps | Host sent a frame before the previous line finished |

## 4. Verification and build flow

1. `scripts/run_sim.py` runs `gen_vectors.py`, then compiles `rtl/` and `sim/` with xvlog. It elaborates each testbench per W with xelab and runs xsim.
2. `tb_siphash24` checks the core alone. `tb_replay` checks both engines and their state isolation. `tb_top` drives UART waveforms into `top_zedboard` and checks the telemetry text. `tb_led_display` checks every LED pattern with a shortened display step. `tb_oled` decodes the OLED's SPI bytes back into a picture, reads the text with the same font, and checks each screen and the power-up order.
3. `scripts/build.py` runs `scripts/build.tcl` in Vivado once per W. Reports go to `reports/W<W>/`, bitstreams to `build/W<W>/`. It then writes `reports/summary.md`.
4. `scripts/build.py --program W` runs `scripts/program.tcl` to load a bitstream over JTAG.
5. `scripts/build.py --variant ps` compiles `sw/uart_bridge` with the Vitis ARM compiler and runs `build.tcl` in `ps` mode. That mode generates the Zynq block design and copies `ps7_init.tcl`. `--variant ps --program W` runs `scripts/program_ps.tcl` in xsdb. It loads the bitstream, initializes the processor, loads the bridge program and starts it.
