"""Regenerate vectors, then run every testbench in Vivado's simulator (xsim).

Usage: python scripts/run_sim.py [--w 16 32 64 128] [--skip-top]

Vivado is found through the VIVADO_BIN environment variable, or the default
install folder below. Paths passed to the Xilinx tools are relative, because
the project folder name contains spaces. Logs go to build/sim/.
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIVADO_BIN = Path(os.environ.get("VIVADO_BIN", r"C:\vivado_2024\Vivado\2024.2\bin"))
WORK = ROOT / "build" / "sim"
REL_ROOT = "../.."  # from WORK back to ROOT

RTL = ["siphash24.v", "auth_stage.v", "strict_counter.v", "sliding_window.v",
       "uart_rx.v", "uart_tx.v", "frame_parser.v", "telemetry.v", "led_display.v",
       "font8x8_rom.v", "oled_status.v", "oled_ssd1306.v", "decision_control.v",
       "top_zedboard.v"]
TBS = ["tb_siphash24.sv", "tb_replay.sv", "tb_top.sv", "tb_led_display.sv", "tb_oled.sv"]


def tool(name: str) -> str:
    exe = VIVADO_BIN / (name + (".bat" if os.name == "nt" else ""))
    if not exe.exists():
        sys.exit(f"Cannot find {exe}. Set VIVADO_BIN to Vivado's bin folder.")
    return str(exe)


def run(args: list[str], log_name: str) -> str:
    result = subprocess.run(args, cwd=WORK, capture_output=True, text=True)
    out = result.stdout + result.stderr
    (WORK / log_name).write_text(out)
    if result.returncode != 0:
        print(out[-3000:])
        sys.exit(f"{Path(args[0]).name} failed, see build/sim/{log_name}")
    return out


def run_with_options(name: str, options: list[str], log_name: str) -> str:
    # The .bat wrappers split arguments at "=", which breaks "W=32" and
    # "VEC=...". Passing the options in a file avoids the Windows shell.
    opt_file = WORK / f"{log_name}.opts"
    opt_file.write_text(" ".join(options) + "\n")
    return run([tool(name), "-f", opt_file.name], log_name)


def simulate(top: str, snapshot: str, generics: list[str]) -> bool:
    elab = [top, "-s", snapshot, "-timescale", "1ns/1ps"]
    for g in generics:
        elab += ["-generic_top", g]
    run_with_options("xelab", elab, f"elab_{snapshot}.log")
    out = run_with_options("xsim", [snapshot, "-runall", "-testplusarg",
                                    f"VEC={REL_ROOT}/sim/vectors"], f"sim_{snapshot}.log")
    summary = [ln for ln in out.splitlines()
               if ln.startswith(("siphash24:", "replay ", "top ", "led_display:", "oled:", "FAIL", "RESULT"))]
    print(f"--- {snapshot}")
    print("\n".join(summary[-12:]))
    return "RESULT: PASS" in out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--w", type=int, nargs="+", default=[16, 32, 64, 128])
    ap.add_argument("--skip-top", action="store_true")
    args = ap.parse_args()

    subprocess.run([sys.executable, str(ROOT / "host" / "gen_vectors.py")], check=True)
    WORK.mkdir(parents=True, exist_ok=True)
    run([tool("xvlog")] + [f"{REL_ROOT}/rtl/{f}" for f in RTL], "xvlog_rtl.log")
    run([tool("xvlog"), "-sv"] + [f"{REL_ROOT}/sim/{f}" for f in TBS], "xvlog_tb.log")

    results = {"siphash": simulate("tb_siphash24", "siphash", []),
               "led_display": simulate("tb_led_display", "led_display", []),
               "oled": simulate("tb_oled", "oled", [])}
    for w in args.w:
        results[f"replay_W{w}"] = simulate("tb_replay", f"replay_W{w}", [f"W={w}"])
        if not args.skip_top:
            for pol in (0, 1):  # switch SW0 down (strict counter) and up (sliding window)
                name = f"top_W{w}_{'SW' if pol else 'SC'}"
                results[name] = simulate("tb_top", name, [f"W={w}", f"POLICY={pol}"])

    print("\n=== Summary")
    for name, ok in results.items():
        print(f"{name:14s} {'PASS' if ok else 'FAIL'}")
    sys.exit(0 if all(results.values()) else 1)


if __name__ == "__main__":
    main()
