"""Text format of the UART telemetry lines sent by rtl/telemetry.v.

Verdict line: SEQ=00000004 MAC=1 STR=0 WIN=1 WR=NEW LAT=000D CNT=0005
Reset line:   RST
Parser error: ERR   (frame cut off by a timeout or a UART framing error)

LAT is the clock-cycle count from frame_valid to the verdict. CNT counts verdicts
since power-on. Both are hexadecimal. Only the part before " LAT=" is predicted
by the golden model, so comparisons use that prefix.
"""

import re

from replay_model import Verdict

VERDICT_RE = re.compile(
    r"^SEQ=([0-9A-F]{8}) MAC=([01]) STR=([01]) WIN=([01]) WR=([A-Z]{3}) "
    r"LAT=([0-9A-F]{4}) CNT=([0-9A-F]{4})$")


def expected_prefix(v: Verdict) -> str:
    return (f"SEQ={v.seq:08X} MAC={int(v.mac_ok)} STR={int(v.strict_accept)} "
            f"WIN={int(v.window_accept)} WR={v.window_reason}")


def parse_verdict(line: str) -> dict | None:
    m = VERDICT_RE.match(line.strip())
    if not m:
        return None
    seq, mac, s, w, wr, lat, cnt = m.groups()
    return {"seq": int(seq, 16), "mac_ok": mac == "1", "strict_accept": s == "1",
            "window_accept": w == "1", "window_reason": wr,
            "latency_cycles": int(lat, 16), "count": int(cnt, 16)}
