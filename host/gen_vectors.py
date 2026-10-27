"""Write the simulation vector files in sim/vectors/ from the golden models.

Usage: python host/gen_vectors.py

Files written (W is each supported window size, P is SC or SW):
  siphash.hex                  8 message bytes then 8 expected tag bytes, per case
  replay_W<W>.hex              one line per step for the replay-engine testbench
  system_W<W>.txt              UART stimulus commands for the full-system testbench
  system_W<W>_P<P>_expected.txt   telemetry lines tb_top must see with switch SW0 = P
"""

import random
from pathlib import Path

from packet import SOF, make_reset
from replay_model import AUT, DUP, INW, NEW, SC, STL, SW
from scenarios import RESET, Burst, all_scenarios
from session import SessionDriver
from siphash import LAB_KEY, siphash24

OUT = Path(__file__).resolve().parents[1] / "sim" / "vectors"
WINDOW_SIZES = (16, 32, 64, 128)
REASON_CODE = {NEW: 0, INW: 1, DUP: 2, STL: 3, AUT: 4}
# Parser timeout used by tb_top, in UART bit times. Must match tb_top.sv.
SIM_TIMEOUT_BITS = 300


def write(name: str, lines: list[str]) -> None:
    (OUT / name).write_text("\n".join(lines) + "\n", newline="\n")


def write_siphash_vectors() -> None:
    rng = random.Random(2024)
    msgs = [bytes(range(8))]  # official test vector entry 8
    msgs += [bytes([0] * 8), bytes([0xFF] * 8)]
    while len(msgs) < 256:
        msgs.append(bytes(rng.randrange(256) for _ in range(8)))
    write("siphash.hex", [(m + siphash24(LAB_KEY, m)).hex() for m in msgs])


def write_replay_vectors(w: int) -> None:
    # Engine-level vectors. Line format, 52 bits as 13 hex digits:
    #   cmd(4) seq(32) mac_ok(4) strict(4) window(4) reason(4)
    # cmd 0 = packet, 1 = session clear (an accepted reset), F = end of list.
    drv = SessionDriver(w)
    lines = []
    for steps in all_scenarios(w).values():
        for step in steps:
            for x in drv.expand(step):
                if x.kind == "reset":
                    if x.reset_ok:
                        lines.append("1" + "0" * 12)
                else:
                    v = x.verdict
                    lines.append(f"0{v.seq:08x}{int(v.mac_ok):x}{int(v.strict_accept):x}"
                                 f"{int(v.window_accept):x}{REASON_CODE[v.window_reason]:x}")
    lines.append("f" + "0" * 12)
    write(f"replay_W{w}.hex", lines)


def write_system_vectors(w: int) -> None:
    cmds: list[str] = []
    expected = {SC: [], SW: []}
    drivers = {pol: SessionDriver(w, pol) for pol in (SC, SW)}

    def send(data: bytes) -> None:
        cmds.extend(f"B {b:02x}" for b in data)

    def step(s) -> None:
        # Both policies see identical frames, only the expected lines differ.
        batches = {pol: drv.expand(s) for pol, drv in drivers.items()}
        for x in batches[SC]:
            send(x.frame)
        cmds.extend("W" for _ in batches[SC])
        for pol in (SC, SW):
            expected[pol].extend(x.expected for x in batches[pol])

    def expect_all(line: str) -> None:
        for pol in (SC, SW):
            expected[pol].append(line)

    # Parser recovery checks first.
    send(bytes([0x11, 0x22, 0x33]))   # junk before a marker is ignored
    step(RESET)
    send(SOF + bytes(7))              # frame cut off part-way
    cmds.append(f"G {SIM_TIMEOUT_BITS + 100}")
    cmds.append("W")
    expect_all("ERR")
    send(SOF + bytes(3))
    cmds.append("E 00")               # byte with a broken stop bit
    cmds.append("W")
    expect_all("ERR")
    cmds.append("G 20")
    # A reset frame cut off part-way must not reset anything.
    send(make_reset(999).frame()[:10])
    cmds.append(f"G {SIM_TIMEOUT_BITS + 100}")
    cmds.append("W")
    expect_all("ERR")
    send(bytes([0xA5]))               # repeated A5 before 5A still syncs

    for steps in all_scenarios(w).values():
        for s in steps:
            step(s)

    write(f"system_W{w}.txt", cmds + ["X"])
    for pol in (SC, SW):
        write(f"system_W{w}_P{pol}_expected.txt", expected[pol])


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("system_W*_expected.txt"):
        if "_P" not in old.name:
            old.unlink()  # format before per-policy expectations
    write_siphash_vectors()
    for w in WINDOW_SIZES:
        write_replay_vectors(w)
        write_system_vectors(w)
    print(f"Vectors written to {OUT}")


if __name__ == "__main__":
    main()
