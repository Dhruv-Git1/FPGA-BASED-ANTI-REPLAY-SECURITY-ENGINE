"""Test scenarios from section 7 of the specification, plus window-edge and random traces.

A scenario is a list of steps. Each step is either the string "reset" (fresh test
session) or a Packet. The same scenarios drive the simulation vectors and the
hardware demo, so both are checked against the same golden model.
"""

import random

from packet import Packet, forge_seq, make_packet, tamper_payload, tamper_tag

Step = str | Packet


def normal_out_of_order_duplicate() -> list[Step]:
    # Spec rows 1-4: in-order 1, 2, then 4 out of order, delayed 3, replayed 3.
    p = {s: make_packet(s, payload=0x1000 + s) for s in range(1, 5)}
    return ["reset", p[1], p[2], p[4], p[3], p[3]]


def auth_failure_isolation() -> list[Step]:
    # Spec rows 5-6: tampered packets must not touch replay state.
    p1 = make_packet(1, payload=0x2001)
    p2 = make_packet(2, payload=0x2002)
    return [
        "reset",
        p1,
        tamper_payload(p2),
        tamper_tag(p2),
        forge_seq(p2, 1_000_000),  # high sequence number with a stolen tag
        p2,                        # both engines still accept 2 as if nothing happened
    ]


def stale(w: int) -> list[Step]:
    # Spec row 7. The spec's literal trace (fresh session, 40, then 1) would make the
    # strict engine ACCEPT 1, because it still expects 1. Sending 1 first makes the
    # expected result match the spec table: strict rejects, window rejects as stale.
    far = w + 8
    return ["reset", make_packet(1), make_packet(far), make_packet(1)]


def window_edges(w: int) -> list[Step]:
    b = 1000
    return [
        "reset",
        make_packet(b),              # NEW, initializes the window
        make_packet(b - (w - 1)),    # oldest slot still inside: INW
        make_packet(b - (w - 1)),    # same again: DUP
        make_packet(b - w),          # one past the edge: STL
        make_packet(b + w),          # advance of exactly W clears the bitmap: NEW
        make_packet(b),              # now W behind: STL
        make_packet(b + w - 1),      # age 1, unseen after the clear: INW
        make_packet(b + w + 3),      # advance 3 shifts the bitmap: NEW
        make_packet(b + w - 1),      # bit moved from 1 to 4, still set: DUP
    ]


def random_trace(seed: int, n: int = 150) -> list[Step]:
    rng = random.Random(seed)
    steps: list[Step] = ["reset"]
    top = 1
    for _ in range(n):
        r = rng.random()
        if r < 0.45:
            top += rng.randint(1, 3)
            seq = top
        elif r < 0.85:
            seq = max(1, top - rng.randint(0, 140))  # replays and late packets
        else:
            seq = top + rng.randint(1, 300)          # big jumps
            top = seq
        pkt = make_packet(seq, device_id=rng.randint(0, 0xFFFF), payload=rng.randint(0, 0xFFFF))
        t = rng.random()
        if t < 0.08:
            pkt = tamper_payload(pkt)
        elif t < 0.12:
            pkt = tamper_tag(pkt)
        steps.append(pkt)
    return steps


def all_scenarios(w: int) -> dict[str, list[Step]]:
    return {
        "normal_ooo_dup": normal_out_of_order_duplicate(),
        "auth_isolation": auth_failure_isolation(),
        "stale": stale(w),
        "window_edges": window_edges(w),
        "random": random_trace(seed=w),
    }
