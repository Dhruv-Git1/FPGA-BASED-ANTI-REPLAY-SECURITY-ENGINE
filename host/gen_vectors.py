"""Write the simulation vector files in sim/vectors/ from the golden models.

Usage: python host/gen_vectors.py

Files written (W is each supported window size):
  siphash.hex            one line per case: 8 message bytes then 8 expected tag bytes
  replay_W<W>.hex        one line per step for the replay-engine testbench
  system_W<W>.txt        UART stimulus commands for the full-system testbench
  system_W<W>_expected.txt   telemetry lines the system testbench must see
"""

import random
from pathlib import Path

from packet import RESET_FRAME, SOF, Packet, make_packet
from replay_model import AntiReplayModel, AUT, DUP, INW, NEW, STL
from scenarios import all_scenarios
from siphash import LAB_KEY, siphash24
from telemetry import expected_prefix

OUT = Path(__file__).resolve().parents[1] / "sim" / "vectors"
WINDOW_SIZES = (16, 32, 64, 128)
REASON_CODE = {NEW: 0, INW: 1, DUP: 2, STL: 3, AUT: 4}
# Parser timeout used by tb_top, in UART bit times. Must match tb_top.sv.
SIM_TIMEOUT_BITS = 300


def write_siphash_vectors() -> None:
    rng = random.Random(2024)
    msgs = [bytes(range(8))]  # official test vector entry 8
    msgs += [bytes([0] * 8), bytes([0xFF] * 8)]
    while len(msgs) < 256:
        msgs.append(bytes(rng.randrange(256) for _ in range(8)))
    lines = [(m + siphash24(LAB_KEY, m)).hex() for m in msgs]
    (OUT / "siphash.hex").write_text("\n".join(lines) + "\n", newline="\n")


def write_replay_vectors(w: int) -> None:
    # Line format, 52 bits as 13 hex digits:
    #   cmd(4) seq(32) mac_ok(4) strict(4) window(4) reason(4)
    # cmd 0 = packet, 1 = session reset, F = end of list.
    model = AntiReplayModel(w)
    lines = []
    for steps in all_scenarios(w).values():
        for s in steps:
            if s == "reset":
                model.reset()
                lines.append("1" + "0" * 12)
            else:
                v = model.process(s)
                lines.append(f"0{v.seq:08x}{int(v.mac_ok):x}{int(v.strict_accept):x}"
                             f"{int(v.window_accept):x}{REASON_CODE[v.window_reason]:x}")
    lines.append("f" + "0" * 12)
    (OUT / f"replay_W{w}.hex").write_text("\n".join(lines) + "\n", newline="\n")


def send(cmds: list[str], data: bytes) -> None:
    cmds.extend(f"B {b:02x}" for b in data)


def write_system_vectors(w: int) -> None:
    model = AntiReplayModel(w)
    cmds: list[str] = []
    expected: list[str] = []

    def packet(p: Packet) -> None:
        send(cmds, p.frame())
        cmds.append("W")
        expected.append(expected_prefix(model.process(p)))

    def reset() -> None:
        send(cmds, RESET_FRAME)
        cmds.append("W")
        model.reset()
        expected.append("RST")

    # Parser recovery checks first.
    send(cmds, bytes([0x11, 0x22, 0x33]))     # junk before a marker is ignored
    reset()
    send(cmds, SOF + bytes(7))                # frame cut off part-way
    cmds.append(f"G {SIM_TIMEOUT_BITS + 100}")
    cmds.append("W")
    expected.append("ERR")
    send(cmds, SOF + bytes(3))
    cmds.append("E 00")                       # byte with a broken stop bit
    cmds.append("W")
    expected.append("ERR")
    cmds.append("G 20")
    send(cmds, bytes([0xA5]))                 # repeated A5 before 5A still syncs
    packet(make_packet(1, payload=0xABCD))

    for steps in all_scenarios(w).values():
        for s in steps:
            if s == "reset":
                reset()
            else:
                packet(s)

    (OUT / f"system_W{w}.txt").write_text("\n".join(cmds) + "\nX\n", newline="\n")
    (OUT / f"system_W{w}_expected.txt").write_text("\n".join(expected) + "\n", newline="\n")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    write_siphash_vectors()
    for w in WINDOW_SIZES:
        write_replay_vectors(w)
        write_system_vectors(w)
    print(f"Vectors written to {OUT}")


if __name__ == "__main__":
    main()
