"""Build bitstreams for several window sizes, then summarize the Vivado reports.

Usage:
  python scripts/build.py                 build W = 16 32 64 128, then summarize
  python scripts/build.py --w 64          build one size
  python scripts/build.py --summary-only  only re-read existing reports
  python scripts/build.py --program 64    load build/W64 onto the board

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
CLOCK_PERIOD_NS = 10.0


def vivado(script: str, w: int, tag: str) -> None:
    exe = VIVADO_BIN / ("vivado.bat" if os.name == "nt" else "vivado")
    log_dir = ROOT / "build" / f"W{w}"
    log_dir.mkdir(parents=True, exist_ok=True)
    # Everything after -tclargs goes to the Tcl script, so -tclargs must come last.
    args = [str(exe), "-mode", "batch", "-log", f"build/W{w}/{tag}.log",
            "-journal", f"build/W{w}/{tag}.jou", "-source", f"scripts/{script}",
            "-tclargs", str(w)]
    print(f"Running Vivado {script} for W={w} ...", flush=True)
    result = subprocess.run(args, cwd=ROOT)
    if result.returncode != 0:
        sys.exit(f"Vivado failed, see build/W{w}/{tag}.log")


def table_value(text: str, row: str) -> str | None:
    m = re.search(r"^\|\s*" + re.escape(row) + r"\s*\|\s*([\d.]+)\s*\|", text, re.M)
    return m.group(1) if m else None


def summarize_one(w: int) -> dict | None:
    rep = ROOT / "reports" / f"W{w}"
    try:
        util = (rep / "impl_utilization.rpt").read_text()
        hier = (rep / "impl_utilization_hier.rpt").read_text()
        timing = (rep / "timing_summary.rpt").read_text()
    except FileNotFoundError:
        return None
    # Design Timing Summary: header line with WNS(ns), a dashed line, then values.
    m = re.search(r"WNS\(ns\)\s+TNS\(ns\).*\n\s*-[- ]+\n\s*(-?[\d.]+)\s+(-?[\d.]+)", timing)
    wns = float(m.group(1)) if m else None
    window = {}
    for line in hier.splitlines():
        cells = [c.strip() for c in line.split("|")]
        if len(cells) > 7 and cells[1] in ("u_window", "u_strict", "u_auth"):
            window[cells[1]] = (cells[3], cells[7])  # Total LUTs, FFs
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
        "",
        "| W | Total LUTs | Total FFs | Slices | WNS (ns) | Est. Fmax (MHz) "
        "| Window LUTs | Window FFs | Strict LUTs | Strict FFs | Auth LUTs | Auth FFs |",
        "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for r in rows:
        win, st, au = r["window"] or ("?", "?"), r["strict"] or ("?", "?"), r["auth"] or ("?", "?")
        lines.append(f"| {r['W']} | {r['LUTs']} | {r['FFs']} | {r['Slices']} | {r['WNS_ns']} "
                     f"| {r['Fmax_MHz']} | {win[0]} | {win[1]} | {st[0]} | {st[1]} "
                     f"| {au[0]} | {au[1]} |")
    out = ROOT / "reports" / "summary.md"
    out.write_text("\n".join(lines) + "\n", newline="\n")
    print("\n".join(lines))
    print(f"\nWritten to {out}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--w", type=int, nargs="+", default=[16, 32, 64, 128])
    ap.add_argument("--summary-only", action="store_true")
    ap.add_argument("--program", type=int, metavar="W")
    args = ap.parse_args()

    if args.program:
        vivado("program.tcl", args.program, "program")
        return
    if not args.summary_only:
        for w in args.w:
            vivado("build.tcl", w, "build")
    summarize(args.w)


if __name__ == "__main__":
    main()
