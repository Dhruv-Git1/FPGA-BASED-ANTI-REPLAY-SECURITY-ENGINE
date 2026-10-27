"""Packet layout and UART framing shared by the vector generator and the hardware demo.

Logical packet, 16 bytes, every field most-significant byte first:
    bytes 0-1   Device_ID
    bytes 2-5   Seq_Num
    bytes 6-7   Payload
    bytes 8-15  MAC_Tag = SipHash-2-4(key, bytes 0-7), in reference output byte order
On the wire each packet is preceded by the start-of-frame marker A5 5A.
The marker A5 C3 (no body) asks the FPGA to reset its replay state.
A5 E1 and A5 E0 tell the FPGA's LED display that a test run passed or failed.
They change only the LEDs.
"""

from dataclasses import dataclass

from siphash import LAB_KEY, siphash24

SOF = bytes([0xA5, 0x5A])
RESET_FRAME = bytes([0xA5, 0xC3])
PASS_FRAME = bytes([0xA5, 0xE1])
FAIL_FRAME = bytes([0xA5, 0xE0])


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


def mac_input(device_id: int, seq: int, payload: int) -> bytes:
    return (device_id.to_bytes(2, "big") + seq.to_bytes(4, "big")
            + payload.to_bytes(2, "big"))


def make_packet(seq: int, device_id: int = 0x0001, payload: int = 0x0000,
                key: bytes = LAB_KEY) -> Packet:
    """Build a packet with a correct tag."""
    tag = siphash24(key, mac_input(device_id, seq, payload))
    return Packet(device_id, seq, payload, tag)


def tamper_payload(pkt: Packet) -> Packet:
    """Change the payload without recomputing the tag, so authentication must fail."""
    return Packet(pkt.device_id, pkt.seq, pkt.payload ^ 0x0001, pkt.tag)


def tamper_tag(pkt: Packet) -> Packet:
    """Flip one tag bit, so authentication must fail."""
    return Packet(pkt.device_id, pkt.seq, pkt.payload,
                  bytes([pkt.tag[0] ^ 0x01]) + pkt.tag[1:])


def forge_seq(pkt: Packet, seq: int) -> Packet:
    """Reuse a valid tag with a different sequence number, as an attacker would try."""
    return Packet(pkt.device_id, seq, pkt.payload, pkt.tag)


def is_authentic(pkt: Packet, key: bytes = LAB_KEY) -> bool:
    return siphash24(key, mac_input(pkt.device_id, pkt.seq, pkt.payload)) == pkt.tag
