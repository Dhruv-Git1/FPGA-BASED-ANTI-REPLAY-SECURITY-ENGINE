"""Golden models of the two replay engines and of the FPGA's decision logic.

These follow section 5 of the project specification and section 4.5 of
RCPROJECT.pdf. The RTL in rtl/strict_counter.v, rtl/sliding_window.v and
rtl/decision_control.v must make the same decisions.
"""

from dataclasses import dataclass

from packet import CMD_CLOSE, CMD_OPEN, Packet, ResetPacket, is_authentic, reset_is_authentic

STRICT_INITIAL_SEQ = 1

# Sliding-window reason codes. The same three-letter text appears in UART telemetry.
NEW = "NEW"  # newer than S_max, or first packet of the session
INW = "INW"  # older than S_max, inside the window, not seen before
DUP = "DUP"  # inside the window, already seen
STL = "STL"  # too old, outside the window
AUT = "AUT"  # authentication failed, state untouched

# Policy selected by switch SW0: 0 = strict counter, 1 = sliding window.
SC, SW = "SC", "SW"


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
class Counts:
    sc_acc: int = 0
    sc_rej: int = 0
    sw_acc: int = 0
    sw_rej: int = 0


@dataclass(frozen=True)
class Verdict:
    seq: int
    cmd: int
    mac_ok: bool
    strict_accept: bool
    window_accept: bool
    window_reason: str
    policy: str
    final_accept: bool
    door_open: bool
    counts: Counts


@dataclass(frozen=True)
class ResetResult:
    accepted: bool
    epoch: int


class AntiReplayModel:
    """Model of the whole FPGA datapath after the frame parser."""

    def __init__(self, w: int, policy: str = SC) -> None:
        self.w = w
        self.policy = policy
        self.last_epoch = 0      # cleared only by power-on
        self.door_open = False   # the "device" the commands control; survives resets
        self._clear_session()

    def _clear_session(self) -> None:
        self.strict = StrictCounter()
        self.window = SlidingWindow(self.w)
        self.counts = Counts()

    def button_reset(self) -> None:
        """BTNC: physical presence, so no tag is needed."""
        self._clear_session()

    def process_reset(self, rst: ResetPacket) -> ResetResult:
        ok = reset_is_authentic(rst) and rst.epoch > self.last_epoch
        if ok:
            self.last_epoch = rst.epoch
            self._clear_session()
        return ResetResult(ok, rst.epoch)

    def process(self, pkt: Packet, policy: str | None = None) -> Verdict:
        pol = policy or self.policy
        mac_ok = is_authentic(pkt)
        s_ok = self.strict.check(pkt.seq, mac_ok)
        w_ok, reason = self.window.check(pkt.seq, mac_ok)
        final = s_ok if pol == SC else w_ok
        if final and pkt.payload == CMD_OPEN:
            self.door_open = True
        elif final and pkt.payload == CMD_CLOSE:
            self.door_open = False
        c = self.counts
        self.counts = Counts(c.sc_acc + s_ok, c.sc_rej + (not s_ok),
                             c.sw_acc + w_ok, c.sw_rej + (not w_ok))
        return Verdict(pkt.seq, pkt.payload, mac_ok, s_ok, w_ok, reason, pol, final,
                       self.door_open, self.counts)
