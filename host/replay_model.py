"""Golden models of the two replay engines and of the FPGA's verdict.

These follow section 5 of the project specification. The RTL in
rtl/strict_counter.v and rtl/sliding_window.v must make the same decisions.
"""

from dataclasses import dataclass

from packet import Packet, is_authentic

STRICT_INITIAL_SEQ = 1

# Sliding-window reason codes. The same three-letter text appears in UART telemetry.
NEW = "NEW"  # newer than S_max, or first packet of the session
INW = "INW"  # older than S_max, inside the window, not seen before
DUP = "DUP"  # inside the window, already seen
STL = "STL"  # too old, outside the window
AUT = "AUT"  # authentication failed, state untouched


class StrictCounter:
    def __init__(self) -> None:
        self.expected_seq = STRICT_INITIAL_SEQ

    def check(self, seq: int, mac_ok: bool) -> bool:
        if mac_ok and seq == self.expected_seq:
            self.expected_seq = (self.expected_seq + 1) & 0xFFFFFFFF
            return True
        return False


class SlidingWindow:
    def __init__(self, w: int) -> None:
        self.w = w
        self.initialized = False
        self.s_max = 0
        self.mask = 0  # bit 0 is S_max, bit k is S_max - k

    def state(self) -> tuple[bool, int, int]:
        return self.initialized, self.s_max, self.mask

    def check(self, seq: int, mac_ok: bool) -> tuple[bool, str]:
        if not mac_ok:
            return False, AUT
        full = (1 << self.w) - 1
        if not self.initialized or seq > self.s_max:
            advance = seq - self.s_max
            if not self.initialized or advance >= self.w:
                self.mask = 1
            else:
                self.mask = ((self.mask << advance) | 1) & full
            self.initialized = True
            self.s_max = seq
            return True, NEW
        age = self.s_max - seq
        if age >= self.w:
            return False, STL
        if (self.mask >> age) & 1:
            return False, DUP
        self.mask |= 1 << age
        return True, INW


@dataclass(frozen=True)
class Verdict:
    seq: int
    mac_ok: bool
    strict_accept: bool
    window_accept: bool
    window_reason: str


class AntiReplayModel:
    """Model of the whole FPGA datapath after the frame parser."""

    def __init__(self, w: int) -> None:
        self.w = w
        self.reset()

    def reset(self) -> None:
        self.strict = StrictCounter()
        self.window = SlidingWindow(self.w)

    def process(self, pkt: Packet) -> Verdict:
        mac_ok = is_authentic(pkt)
        s_ok = self.strict.check(pkt.seq, mac_ok)
        w_ok, reason = self.window.check(pkt.seq, mac_ok)
        return Verdict(pkt.seq, mac_ok, s_ok, w_ok, reason)
