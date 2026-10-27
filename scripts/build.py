"""Build bitstreams for several window sizes, then summarize the Vivado reports.

Usage:
  python scripts/build.py                 build W = 16 32 64 128, then summarize
  python scripts/build.py --w 64          build one size
  python scripts/build.py --summary-only  only re-read existing reports
  python scripts/build.py --program 64    load build/W64 onto the board

  Variant "ps" (PC link through the ZedBoard's own J14 USB-UART, relayed by the ARM):
  python scripts/build.py --variant ps --w 64          bitstream and ARM bridge program
  python scripts/build.py --variant ps --program 64    load both and start the bridge
  python scripts/build.py --firmware                   only compile the ARM bridge

All numbers in reports/summary.md are read from Vivado's own report files.
Estimated Fmax = 1 / (clock period - WNS), the usual first-order estimate from
setup slack. It is an estimate, not a measured frequency.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIVADO_BIN = Path(os.environ.get("VIVADO_BIN", r"C:\vivado_2024\Vivado\2024.2\bin"))
VITIS_GCC_BIN = Path(os.environ.get(
    "VITIS_GCC_BIN", r"C:\vivado_2024\Vitis\2024.2\gnu\aarch32\nt\gcc-arm-none-eabi\bin"))
CLOCK_PERIOD_NS = 10.0


def build_dir(w: int, variant: str) -> str:
    return f"ps_W{w}" if variant == "ps" else f"W{w}"


def vivado(script: str, w: int, tag: str, variant: str = "pmod") -> None:
    exe = VIVADO_BIN / ("vivado.bat" if os.name == "nt" else "vivado")
    d = build_dir(w, variant)
    (ROOT / "build" / d).mkdir(parents=True, exist_ok=True)
    # Everything after -tclargs goes to the Tcl script, so -tclargs must come last.
    args = [str(exe), "-mode", "batch", "-log", f"build/{d}/{tag}.log",
            "-journal", f"build/{d}/{tag}.jou", "-source", f"scripts/{script}",
            "-tclargs", str(w), variant]
    print(f"Running Vivado {script} for W={w} ({variant}) ...", flush=True)
    result = subprocess.run(args, cwd=ROOT)
    if result.returncode != 0:
        sys.exit(f"Vivado failed, see build/{d}/{tag}.log")


def build_firmware() -> None:
    """Compile the ARM bridge program (sw/uart_bridge) to build/sw/uart_bridge.elf."""
    gcc = VITIS_GCC_BIN / ("arm-none-eabi-gcc.exe" if os.name == "nt" else "arm-none-eabi-gcc")
    (ROOT / "build" / "sw").mkdir(parents=True, exist_ok=True)
    src = "sw/uart_bridge"
    args = [str(gcc), "-mcpu=cortex-a9", "-marm", "-O2", "-Wall", "-Wextra", "-ffreestanding",
            "-nostdlib", "-T", f"{src}/link.ld", f"{src}/start.S", f"{src}/main.c",
            "-o", "build/sw/uart_bridge.elf"]
    print("Compiling ARM bridge program ...", flush=True)
    if subprocess.run(args, cwd=ROOT).returncode != 0:
        sys.exit("ARM compile failed")


def program_ps(w: int) -> None:
    exe = VIVADO_BIN / ("xsdb.bat" if os.name == "nt" else "xsdb")
    print(f"Loading ps_W{w} and starting the ARM bridge ...", flush=True)
    if subprocess.run([str(exe), "scripts/program_ps.tcl", str(w)], cwd=ROOT).returncode != 0:
        sys.exit("xsdb failed")


def table_value(text: str, row: str) -> str | None:
    m = re.search(r"^\|\s*" + re.escape(row) + r"\s*\|\s*([\d.]+)\s*\|", text, re.M)
    return m.group(1) if m else None


def summarize_one(w: int) -> dict | None:
    rep = ROOT / "reports" / f"W{w}"  # the comparison table uses the pmod variant
    try:
        util = (rep / "impl_utilization.rpt").read_text()
        hier = (rep / "impl_utilization_hier.rpt").read_text()
        timing = (rep / "timing_summary.rpt").read_text()
        paths = (rep / "critical_paths.rpt").read_text()
    except FileNotFoundError:
        return None
    # Design Timing Summary: header line with WNS(ns), a dashed line, then values.
    m = re.search(r"WNS\(ns\)\s+TNS\(ns\).*\n\s*-[- ]+\n\s*(-?[\d.]+)\s+(-?[\d.]+)", timing)
    wns = float(m.group(1)) if m else None
    window = {}
    for line in hier.splitlines():
        cells = [c.strip() for c in line.split("|")]
        if len(cells) > 7 and cells[1] in ("u_window", "u_strict", "u_auth", "u_decide"):
            window[cells[1]] = (cells[3], cells[7])  # Total LUTs, FFs
    # Which module the worst path starts and ends in, so readers can tell an
    # effect of W from placement noise.
    src = re.search(r"Source:\s+(\S+)", paths)
    dst = re.search(r"Destination:\s+(\S+)", paths)
    where = "?"
    if src and dst:
        def owner(cell: str) -> str:
            for key, name in (("u_sip", "SipHash"), ("u_window", "window"), ("u_strict", "strict"),
                              ("u_decide", "decision"), ("u_auth", "auth"), ("u_tel", "telemetry"),
                              ("u_oled", "OLED"), ("u_leds", "LEDs")):
                if key in cell:
                    return name
            return "top"
        a, b = owner(src.group(1)), owner(dst.group(1))
        where = a if a == b else f"{a} to {b}"
    return {
        "W": w,
        "LUTs": table_value(util, "Slice LUTs"),
        "FFs": table_value(util, "Slice Registers"),
        "Slices": table_value(util, "Slice"),
        "WNS_ns": wns,
        "Fmax_MHz": round(1000.0 / (CLOCK_PERIOD_NS - wns), 1) if wns is not None else None,
        "window": window.get("u_window"),
        "strict": window.get("u_strict"),
        "auth": window.get("u_auth"),
        "decide": window.get("u_decide"),
        "where": where,
    }


def summarize(ws: list[int]) -> None:
    rows = [r for r in (summarize_one(w) for w in ws) if r]
    if not rows:
        print("No reports found.")
        return
    lines = [
        "# Implementation results (read from Vivado reports)",
        "",
        "Part xc7z020clg484-1, clock constraint 10.000 ns (100 MHz), same settings for every W.",
        "Estimated Fmax = 1 / (10 ns - WNS). It is derived from setup slack, not measured.",
        "Each row is one placement run. When the critical path is not in the window logic,",
        "differences in WNS and Fmax between rows are placement noise, not an effect of W.",
        "",
        "| W | Total LUTs | Total FFs | Slices | WNS (ns) | Est. Fmax (MHz) | Critical path "
        "| Window LUTs | Window FFs | Strict LUTs | Strict FFs | Auth LUTs | Auth FFs "
        "| Decision LUTs | Decision FFs |",
        "|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for r in rows:
        win, st, au, de = (r[k] or ("?", "?") for k in ("window", "strict", "auth", "decide"))
        lines.append(f"| {r['W']} | {r['LUTs']} | {r['FFs']} | {r['Slices']} | {r['WNS_ns']} "
                     f"| {r['Fmax_MHz']} | {r['where']} | {win[0]} | {win[1]} | {st[0]} | {st[1]} "
                     f"| {au[0]} | {au[1]} | {de[0]} | {de[1]} |")
    out = ROOT / "reports" / "summary.md"
    out.write_text("\n".join(lines) + "\n", newline="\n")
    print("\n".join(lines))
    print(f"\nWritten to {out}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--w", type=int, nargs="+", default=[16, 32, 64, 128])
    ap.add_argument("--summary-only", action="store_true")
    ap.add_argument("--program", type=int, metavar="W")
    ap.add_argument("--variant", choices=["pmod", "ps"], default="pmod")
    ap.add_argument("--firmware", action="store_true", help="only compile the ARM bridge")
    args = ap.parse_args()

    if args.firmware:
        build_firmware()
        return
    if args.program:
        if args.variant == "ps":
            program_ps(args.program)
        else:
            vivado("program.tcl", args.program, "program")
        return
    if args.variant == "ps":
        build_firmware()
        for w in args.w:
            vivado("build.tcl", w, "build", "ps")
        return
    if not args.summary_only:
        for w in args.w:
            vivado("build.tcl", w, "build")
    summarize(args.w)


if __name__ == "__main__":
    main()
