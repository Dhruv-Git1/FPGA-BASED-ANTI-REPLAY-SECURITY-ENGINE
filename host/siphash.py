"""Plain-Python SipHash-2-4 reference model.

Follows Aumasson and Bernstein, "SipHash: a fast short-input PRF" (2012).
The RTL core in rtl/siphash24.v must produce the same 64-bit result.
"""

MASK64 = (1 << 64) - 1

# The fixed laboratory key used by both the PC and the FPGA: bytes 00 01 .. 0f.
# It equals the key of the official test vectors, so the RTL can be checked
# against published values. It is not a secret and not a production key.
LAB_KEY = bytes(range(16))


def _rotl(x: int, b: int) -> int:
    return ((x << b) | (x >> (64 - b))) & MASK64


def sipround(v0: int, v1: int, v2: int, v3: int) -> tuple[int, int, int, int]:
    v0 = (v0 + v1) & MASK64
    v1 = _rotl(v1, 13) ^ v0
    v0 = _rotl(v0, 32)
    v2 = (v2 + v3) & MASK64
    v3 = _rotl(v3, 16) ^ v2
    v0 = (v0 + v3) & MASK64
    v3 = _rotl(v3, 21) ^ v0
    v2 = (v2 + v1) & MASK64
    v1 = _rotl(v1, 17) ^ v2
    v2 = _rotl(v2, 32)
    return v0, v1, v2, v3


def siphash24_int(key: bytes, msg: bytes) -> int:
    """Return the SipHash-2-4 output as a 64-bit integer."""
    if len(key) != 16:
        raise ValueError("SipHash key must be 16 bytes")
    k0 = int.from_bytes(key[0:8], "little")
    k1 = int.from_bytes(key[8:16], "little")
    v0 = k0 ^ 0x736F6D6570736575
    v1 = k1 ^ 0x646F72616E646F6D
    v2 = k0 ^ 0x6C7967656E657261
    v3 = k1 ^ 0x7465646279746573

    full = len(msg) - (len(msg) % 8)
    blocks = [int.from_bytes(msg[i:i + 8], "little") for i in range(0, full, 8)]
    # Final block: leftover bytes in little-endian order, message length in the top byte.
    tail = int.from_bytes(msg[full:], "little")
    blocks.append(tail | ((len(msg) & 0xFF) << 56))

    for m in blocks:
        v3 ^= m
        for _ in range(2):
            v0, v1, v2, v3 = sipround(v0, v1, v2, v3)
        v0 ^= m

    v2 ^= 0xFF
    for _ in range(4):
        v0, v1, v2, v3 = sipround(v0, v1, v2, v3)
    return v0 ^ v1 ^ v2 ^ v3


def siphash24(key: bytes, msg: bytes) -> bytes:
    """Return the 8 output bytes in the order the reference C code writes them (little-endian)."""
    return siphash24_int(key, msg).to_bytes(8, "little")
