"""Turn scenario steps into the frames to send and the telemetry lines to expect.

Used by host/gen_vectors.py (simulation) and host/demo.py (hardware), so both run
the same frames against the same golden model.
"""

from dataclasses import dataclass

from packet import Packet, ResetPacket, forge_reset, make_reset
from replay_model import SC, AntiReplayModel, Verdict
from scenarios import FORGED_RESET, REPLAY_RESET, RESET, Burst
from telemetry import expected_line, expected_reset_line


@dataclass
class Exchange:
    frame: bytes
    expected: str
    kind: str     # "data" or "reset"
    seq: int      # sequence number or epoch, for messages
    verdict: Verdict | None = None   # data frames: the model's full verdict
    reset_ok: bool = False           # reset frames: whether the model accepted it


class SessionDriver:
    def __init__(self, w: int, policy: str = SC, first_epoch: int = 1) -> None:
        self.model = AntiReplayModel(w, policy)
        self.next_epoch = first_epoch
        self.last_reset: ResetPacket | None = None

    def _reset(self, rst: ResetPacket) -> Exchange:
        r = self.model.process_reset(rst)
        if r.accepted:
            self.last_reset = rst
        return Exchange(rst.frame(), expected_reset_line(r, self.model.policy), "reset", rst.epoch,
                        reset_ok=r.accepted)

    def expand(self, step) -> list[Exchange]:
        """Frames for one step. A Burst returns several, all sent before any reply is read."""
        if isinstance(step, Burst):
            return [x for s in step.steps for x in self.expand(s)]
        if step == RESET:
            rst = make_reset(self.next_epoch)
            self.next_epoch += 1
            return [self._reset(rst)]
        if step == FORGED_RESET:
            rst = forge_reset(self.next_epoch)
            self.next_epoch += 1
            return [self._reset(rst)]
        if step == REPLAY_RESET:
            if self.last_reset is None:
                raise ValueError("REPLAY_RESET before any accepted reset")
            return [self._reset(self.last_reset)]
        assert isinstance(step, Packet)
        v = self.model.process(step)
        return [Exchange(step.frame(), expected_line(v), "data", step.seq, verdict=v)]
