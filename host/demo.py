"""Run the test scenarios on the real ZedBoard and check every telemetry line.

Usage:
  python host/demo.py --list                     show serial ports
  python host/demo.py --port COM8 --w 64         run all scenarios
  python host/demo.py --port COM8 --w 64 --step  pause before each step to watch the board
  python host/demo.py --port COM8 --w 64 --watch 3 --only normal_ooo_dup
                                                 3 s between steps, one scenario only

--w must equal the window size of the bitstream on the board. The policy is read
from the board: every scenario starts with a signed reset, and the reply
"RST EPOCH=... POL=SC|SW" reports switch SW0. Flipping SW0 between scenarios is
therefore fine. Session epochs start from the current Unix time, so they are
always higher than any epoch an earlier run used since the board was programmed.

Frames inside a Burst step are sent back to back before any reply is read. The
FPGA queues its telemetry, so every line must still arrive, in order.
A log is written to logs/. At the end the board shows the overall result on the
OLED and LEDs (display-only frames A5 E1 / A5 E0).
"""

import argparse
import sys
import time
from datetime import datetime
from pathlib import Path

import serial
from serial.tools import list_ports

from packet import FAIL_FRAME, PASS_FRAME, SOF
from scenarios import Burst, all_scenarios
from session import SessionDriver
from telemetry import matches, parse_verdict, reset_policy

LOG_DIR = Path(__file__).resolve().parents[1] / "logs"
LINE_TIMEOUT_S = 1.0
PARSER_TIMEOUT_S = 0.010  # frame_parser abandons a frame after 10 ms of silence


class Board:
    def __init__(self, port: str, baud: int, log) -> None:
        self.ser = serial.Serial(port, baud, timeout=LINE_TIMEOUT_S)
        self.log = log
        time.sleep(0.1)
        self.ser.reset_input_buffer()

    def readline(self) -> str:
        return self.ser.readline().decode("ascii", errors="replace").strip()

    def exchange(self, frames: list[bytes]) -> tuple[list[str], float]:
        """Send all frames back to back, then read one line per frame."""
        start = time.perf_counter()
        self.ser.write(b"".join(frames))
        lines = [self.readline() for _ in frames]
        elapsed = time.perf_counter() - start
        for f, ln in zip(frames, lines):
            self.log(f"  sent {f.hex(' ')}\n  got  {ln or '<timeout>'}")
        self.log(f"  ({elapsed * 1000:.1f} ms for {len(frames)} frame(s))")
        return lines, elapsed


def describe(step) -> str:
    if isinstance(step, Burst):
        return f"burst of {len(step.steps)}"
    return step if isinstance(step, str) else f"seq {step.seq}"


def run(args) -> int:
    LOG_DIR.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = LOG_DIR / f"demo_W{args.w}_{stamp}.log"
    log_file = log_path.open("w", newline="\n")

    def log(msg: str) -> None:
        log_file.write(msg + "\n")
        if args.verbose:
            print(msg)

    board = Board(args.port, args.baud, log)
    drv = SessionDriver(args.w, first_epoch=int(time.time()))
    total_fail = 0
    latencies, round_trips = set(), []

    # Parser recovery: a frame cut off part-way must give ERR, and the next frame must work.
    print("parser_recovery")
    board.ser.write(SOF + bytes(7))
    time.sleep(PARSER_TIMEOUT_S * 5)
    line = board.readline()
    log(f"  cut-off frame -> {line or '<timeout>'}")
    ok = line == "ERR"
    print(f"  cut-off frame reports ERR    {'PASS' if ok else 'FAIL (' + line + ')'}")
    total_fail += not ok

    scenarios = all_scenarios(args.w)
    if args.only:
        scenarios = {n: s for n, s in scenarios.items() if n in args.only}
    for name, steps in scenarios.items():
        print(name)
        log(f"== {name}")
        fails = 0
        show = args.step or args.watch or len(steps) < 12
        for step in steps:
            if args.step:
                input(f"  Enter to send {describe(step)} ...")
            elif args.watch:
                time.sleep(args.watch)
            exchanges = drv.expand(step)
            lines, elapsed = board.exchange([x.frame for x in exchanges])
            if len(exchanges) == 1:
                round_trips.append(elapsed)
            for x, line in zip(exchanges, lines):
                ok = matches(line, x.expected)
                pol = reset_policy(line)
                if not ok and x.kind == "reset" and pol and x.reset_ok:
                    # SW0 was flipped since the last scenario: follow the board.
                    ok = matches(line[:-2] + "??", x.expected[:-2] + "??")
                if pol:
                    drv.model.policy = pol
                got = parse_verdict(line)
                if got:
                    latencies.add(got["latency_cycles"])
                if not ok:
                    fails += 1
                    print(f"  MISMATCH expected '{x.expected}'\n           got      '{line}'")
                elif show:
                    print(f"  {line}")
        print(f"  {'PASS' if fails == 0 else f'FAIL ({fails} mismatches)'}")
        total_fail += fails

    if round_trips:
        avg = sum(round_trips) / len(round_trips)
        print(f"\nCore latency reported by FPGA: {sorted(latencies)} clock cycles")
        print(f"Average PC round trip per frame (UART + USB + telemetry line): {avg * 1000:.1f} ms")
        log(f"latency_cycles={sorted(latencies)} avg_round_trip_ms={avg * 1000:.2f}")
    if args.watch:
        time.sleep(args.watch)
    # Display only: tells the OLED and LEDs the overall result. It changes no replay state.
    board.ser.write(PASS_FRAME if total_fail == 0 else FAIL_FRAME)
    board.ser.flush()
    print(f"\n{'ALL PASS' if total_fail == 0 else f'{total_fail} FAILURES'}. Log: {log_path}")
    log_file.close()
    return 0 if total_fail == 0 else 1


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port")
    ap.add_argument("--w", type=int, default=64)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--step", action="store_true")
    ap.add_argument("--watch", type=float, default=0.0, metavar="SECONDS",
                    help="wait this long before each step so the OLED and LEDs can be followed")
    ap.add_argument("--only", nargs="+", metavar="SCENARIO",
                    help="run only these: " + " ".join(all_scenarios(64)))
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    if args.list or not args.port:
        for p in list_ports.comports():
            print(f"{p.device:8s} {p.description}")
        if not args.port:
            print("Pass --port with the board's serial port.")
        return
    sys.exit(run(args))


if __name__ == "__main__":
    main()
