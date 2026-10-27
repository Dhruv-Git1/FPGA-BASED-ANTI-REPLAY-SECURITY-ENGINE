"""Run the test scenarios on the real ZedBoard and check every telemetry line.

Usage:
  python host/demo.py --list                     show serial ports
  python host/demo.py --port COM5 --w 64         run all scenarios
  python host/demo.py --port COM5 --w 64 --step  pause before each packet to watch the LEDs
  python host/demo.py --port COM5 --w 64 --watch 1.5 --only normal_ooo_dup
                                                 1.5 s between packets, one scenario only

--w must equal the window size of the bitstream on the board. Each frame is sent,
then the script waits for its telemetry line before sending the next one, because
the FPGA drops events that arrive while a line is still being sent. A log is
written to logs/. At the end the board's LEDs show the overall result: all on
for PASS, all blinking for FAIL.
"""

import argparse
import sys
import time
from datetime import datetime
from pathlib import Path

import serial
from serial.tools import list_ports

from packet import FAIL_FRAME, PASS_FRAME, RESET_FRAME, SOF, Packet
from replay_model import AntiReplayModel
from scenarios import all_scenarios
from telemetry import expected_prefix, parse_verdict

LOG_DIR = Path(__file__).resolve().parents[1] / "logs"
LINE_TIMEOUT_S = 1.0
PARSER_TIMEOUT_S = 0.010  # frame_parser abandons a frame after 10 ms of silence


class Board:
    def __init__(self, port: str, baud: int, log) -> None:
        self.ser = serial.Serial(port, baud, timeout=LINE_TIMEOUT_S)
        self.log = log
        time.sleep(0.1)
        self.ser.reset_input_buffer()

    def exchange(self, data: bytes) -> tuple[str, float]:
        start = time.perf_counter()
        self.ser.write(data)
        line = self.ser.readline().decode("ascii", errors="replace").strip()
        elapsed = time.perf_counter() - start
        self.log(f"  sent {data.hex(' ')}\n  got  {line or '<timeout>'}  ({elapsed * 1000:.1f} ms)")
        return line, elapsed


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
    model = AntiReplayModel(args.w)
    total_fail = 0
    latencies, round_trips = set(), []

    # Parser recovery: a frame cut off part-way must give ERR, and the next frame must work.
    print("parser_recovery")
    board.ser.write(SOF + bytes(7))
    time.sleep(PARSER_TIMEOUT_S * 5)
    line = board.ser.readline().decode("ascii", errors="replace").strip()
    log(f"  cut-off frame -> {line or '<timeout>'}")
    ok = line == "ERR"
    print(f"  cut-off frame reports ERR       {'PASS' if ok else 'FAIL (' + line + ')'}")
    total_fail += not ok

    scenarios = all_scenarios(args.w)
    if args.only:
        scenarios = {n: s for n, s in scenarios.items() if n in args.only}
    for name, steps in scenarios.items():
        print(name)
        log(f"== {name}")
        fails = 0
        for step in steps:
            if args.step:
                input(f"  Enter to send {'reset' if step == 'reset' else 'seq ' + str(step.seq)} ...")
            elif args.watch:
                time.sleep(args.watch)
            if step == "reset":
                model.reset()
                line, _ = board.exchange(RESET_FRAME)
                ok, want = line == "RST", "RST"
            else:
                assert isinstance(step, Packet)
                want = expected_prefix(model.process(step))
                line, rt = board.exchange(step.frame())
                round_trips.append(rt)
                got = parse_verdict(line)
                ok = got is not None and line.startswith(want)
                if got:
                    latencies.add(got["latency_cycles"])
            if not ok:
                fails += 1
                print(f"  MISMATCH expected '{want}'\n           got      '{line}'")
            elif args.step or args.watch or len(steps) < 12:
                print(f"  {line}")
        print(f"  {'PASS' if fails == 0 else f'FAIL ({fails} mismatches)'}")
        total_fail += fails

    if round_trips:
        avg = sum(round_trips) / len(round_trips)
        print(f"\nCore latency reported by FPGA: {sorted(latencies)} clock cycles")
        print(f"Average PC round trip per packet (UART + USB + telemetry line): {avg * 1000:.1f} ms")
        log(f"latency_cycles={sorted(latencies)} avg_round_trip_ms={avg * 1000:.2f}")
    if args.watch:
        time.sleep(args.watch)
    # Display only: tells the LEDs the overall result. It changes no replay state.
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
                    help="wait this long before each packet so the LED animation can be followed")
    ap.add_argument("--only", nargs="+", metavar="SCENARIO",
                    help="run only these: normal_ooo_dup auth_isolation stale window_edges random")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    if args.list or not args.port:
        for p in list_ports.comports():
            print(f"{p.device:8s} {p.description}")
        if not args.port:
            print("Pass --port with the Pmod USBUART's port (its description mentions FT232R/USB Serial).")
        return
    sys.exit(run(args))


if __name__ == "__main__":
    main()
