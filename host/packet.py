"""Packet layout and UART framing shared by the vector generator and the hardware demo.

Logical packet, 16 bytes, every field most-significant byte first:
    bytes 0-1   Device_ID
    bytes 2-5   Seq_Num
    bytes 6-7   Payload (a command code, see COMMANDS)
    bytes 8-15  MAC_Tag = SipHash-2-4(key, bytes 0-7), in reference output byte order

Frames on the wire:
    A5 5A + 16-byte data packet, tagged with LAB_KEY
    A5 C3 + 16-byte reset packet, tagged with RESET_KEY. Its Seq_Num field carries
          the session epoch, which must be higher than the last accepted one.
          A different key means a data packet's tag can never pass as a reset.
    A5 E1 / A5 E0 tell the FPGA's LED and OLED display that a test run passed or
          failed. They change only the display.
"""

from dataclasses import dataclass

from siphash import LAB_KEY, siphash24

SOF = bytes([0xA5, 0x5A])
RESET_SOF = bytes([0xA5, 0xC3])
PASS_FRAME = bytes([0xA5, 0xE1])
FAIL_FRAME = bytes([0xA5, 0xE0])

# Separate laboratory key for reset frames: bytes 10 11 .. 1f.
RESET_KEY = bytes(range(0x10, 0x20))

# Payload values the FPGA executes as commands, only after a final ACCEPT.
CMD_OPEN, CMD_CLOSE, CMD_STATUS = 0x0001, 0x0002, 0x0003
COMMANDS = {CMD_OPEN: "OPEN", CMD_CLOSE: "CLOSE", CMD_STATUS: "STATUS"}


@dataclass(frozen=True)
class Packet:
    device_id: int
    seq: int
    payload: int
    tag: bytes

    def to_bytes(self) -> bytes:
        return mac_input(self.device_id, self.seq, self.payload) + self.tag

    def frame(self) -> bytes:
        return SOF + self.to_bytes()


@dataclass(frozen=True)
class ResetPacket:
    epoch: int
    tag: bytes

    def frame(self) -> bytes:
        return RESET_SOF + mac_input(0, self.epoch, 0) + self.tag


def mac_input(device_id: int, seq: int, payload: int) -> bytes:
    return (device_id.to_bytes(2, "big") + seq.to_bytes(4, "big")
            + payload.to_bytes(2, "big"))


def make_packet(seq: int, device_id: int = 0x0001, payload: int = 0x0000,
                key: bytes = LAB_KEY) -> Packet:
    """Build a packet with a correct tag."""
    tag = siphash24(key, mac_input(device_id, seq, payload))
    return Packet(device_id, seq, payload, tag)


def make_reset(epoch: int, key: bytes = RESET_KEY) -> ResetPacket:
    """Build a signed reset for a new session epoch."""
    return ResetPacket(epoch, siphash24(key, mac_input(0, epoch, 0)))


def forge_reset(epoch: int) -> ResetPacket:
    """A reset an attacker could build without the key: the tag is wrong."""
    good = make_reset(epoch)
    return ResetPacket(epoch, bytes([good.tag[0] ^ 0x01]) + good.tag[1:])


def tamper_payload(pkt: Packet) -> Packet:
    """Change the payload without recomputing the tag, so authentication must fail."""
    return Packet(pkt.device_id, pkt.seq, pkt.payload ^ 0x0001, pkt.tag)


def tamper_tag(pkt: Packet) -> Packet:
    """Flip one tag bit, so authentication must fail."""
    return Packet(pkt.device_id, pkt.seq, pkt.payload,
                  bytes([pkt.tag[0] ^ 0x01]) + pkt.tag[1:])


def tamper_device(pkt: Packet) -> Packet:
    """Change Device_ID without recomputing the tag, so authentication must fail."""
    return Packet(pkt.device_id ^ 0x0100, pkt.seq, pkt.payload, pkt.tag)


def forge_seq(pkt: Packet, seq: int) -> Packet:
    """Reuse a valid tag with a different sequence number, as an attacker would try."""
    return Packet(pkt.device_id, seq, pkt.payload, pkt.tag)


def is_authentic(pkt: Packet, key: bytes = LAB_KEY) -> bool:
    return siphash24(key, mac_input(pkt.device_id, pkt.seq, pkt.payload)) == pkt.tag


def reset_is_authentic(rst: ResetPacket) -> bool:
    return siphash24(RESET_KEY, mac_input(0, rst.epoch, 0)) == rst.tag
