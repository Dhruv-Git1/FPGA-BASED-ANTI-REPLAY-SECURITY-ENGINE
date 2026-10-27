"""Test scenarios from section 7 of the specification and RCPROJECT.pdf, plus attacks.

A scenario is a list of steps:
  RESET         a signed reset with the next session epoch (fresh test session)
  FORGED_RESET  a reset with a wrong tag, as an attacker without the key would send
  REPLAY_RESET  the last accepted reset frame, byte for byte
  a Packet      a data frame
  Burst(...)    several of the above sent back to back without waiting for replies
host/session.py turns steps into frames and expected telemetry lines, so the
simulation and the hardware demo check the same expectations.
"""

import random
from dataclasses import dataclass

from packet import (CMD_CLOSE, CMD_OPEN, CMD_STATUS, Packet, forge_seq, make_packet,
                    tamper_device, tamper_payload, tamper_tag)

RESET, FORGED_RESET, REPLAY_RESET = "reset", "forged_reset", "replay_reset"


@dataclass(frozen=True)
class Burst:
    steps: tuple


Step = str | Packet | Burst


def normal_out_of_order_duplicate() -> list[Step]:
    # Spec rows 1-4: in-order 1, 2, then 4 out of order, delayed 3, replayed 3.
    p = {1: make_packet(1, payload=CMD_OPEN), 2: make_packet(2, payload=CMD_CLOSE),
         3: make_packet(3, payload=CMD_STATUS), 4: make_packet(4, payload=CMD_STATUS)}
    return [RESET, p[1], p[2], p[4], p[3], p[3]]


def auth_failure_isolation() -> list[Step]:
    # Spec rows 5-6: tampered packets must not touch replay state.
    p1 = make_packet(1, payload=CMD_STATUS)
    p2 = make_packet(2, payload=CMD_OPEN)
    return [
        RESET,
        p1,
        tamper_payload(p2),
        tamper_tag(p2),
        tamper_device(p2),         # Device_ID is covered by the tag too
        forge_seq(p2, 1_000_000),  # high sequence number with a stolen tag
        p2,                        # both engines still accept 2 as if nothing happened
    ]


def replayed_command() -> list[Step]:
    # A recorded OPEN replayed after CLOSE must not reopen the door.
    p1 = make_packet(1, payload=CMD_OPEN)
    p2 = make_packet(2, payload=CMD_CLOSE)
    return [RESET, p1, p2, p1]


def reset_attacks() -> list[Step]:
    # An attacker cannot wipe replay state to make an old packet acceptable again.
    p1 = make_packet(1, payload=CMD_OPEN)
    p2 = make_packet(2, payload=CMD_CLOSE)
    return [
        RESET, p1, p2,
        FORGED_RESET, p1,          # forged reset denied, so p1 is still a replay
        REPLAY_RESET, p1,          # replayed old reset denied, p1 still a replay
        Burst((REPLAY_RESET, p1)), # same attack without pauses: nothing is lost from the log
    ]


def burst() -> list[Step]:
    # Frames back to back. Every verdict line must still arrive, in order.
    return [RESET, Burst(tuple(make_packet(s, payload=CMD_STATUS) for s in (1, 2, 4, 3, 3, 5)))]


def stale(w: int) -> list[Step]:
    # Spec row 7. The spec's literal trace (fresh session, 40, then 1) would make the
    # strict engine ACCEPT 1, because it still expects 1. Sending 1 first makes the
    # expected result match the spec table: strict rejects, window rejects as stale.
    far = w + 8
    return [RESET, make_packet(1), make_packet(far), make_packet(1)]


def window_edges(w: int) -> list[Step]:
    b = 1000
    return [
        RESET,
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
    steps: list[Step] = [RESET]
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
        if t < 0.06:
            pkt = tamper_payload(pkt)
        elif t < 0.09:
            pkt = tamper_tag(pkt)
        elif t < 0.12:
            pkt = tamper_device(pkt)
        steps.append(pkt)
    return steps


def all_scenarios(w: int) -> dict[str, list[Step]]:
    return {
        "normal_ooo_dup": normal_out_of_order_duplicate(),
        "auth_isolation": auth_failure_isolation(),
        "replayed_command": replayed_command(),
        "reset_attacks": reset_attacks(),
        "burst": burst(),
        "stale": stale(w),
        "window_edges": window_edges(w),
        "random": random_trace(seed=w),
    }
