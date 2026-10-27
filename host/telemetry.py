"""Text format of the UART telemetry lines sent by rtl/telemetry.v.

Verdict line (one line, shown wrapped):
  SEQ=00000004 CMD=0001 MAC=1 STR=0 WIN=1 WR=NEW POL=SW RES=ACC DOOR=O
  LAT=000C CNT=0005 SC=0003/0001 SW=0004/0000
Reset lines:   RST EPOCH=0000000A POL=SC   (signed reset accepted, new session)
               RST DENIED           (bad tag or epoch not higher, state kept)
               RST BUTTON           (BTNC pressed)
Parser error:  ERR                  (frame cut off by a timeout or a UART framing error)

POL is the policy chosen by switch SW0 and RES is the final decision under it.
DOOR is the state the OPEN and CLOSE commands control (O open, C closed).
LAT is clocks from frame_valid to verdict and CNT counts verdicts since power-on,
both hexadecimal. SC and SW give accepted/rejected counts per engine for the
current session, in decimal. LAT and CNT are not predicted by the golden model,
so expected lines carry '?' there and matches() treats '?' as any character.
"""

import re

from replay_model import ResetResult, Verdict

VERDICT_RE = re.compile(
    r"^SEQ=([0-9A-F]{8}) CMD=([0-9A-F]{4}) MAC=([01]) STR=([01]) WIN=([01]) WR=([A-Z]{3}) "
    r"POL=(SC|SW) RES=(ACC|REJ) DOOR=([OC]) LAT=([0-9A-F]{4}) CNT=([0-9A-F]{4}) "
    r"SC=(\d{4})/(\d{4}) SW=(\d{4})/(\d{4})$")


def expected_line(v: Verdict) -> str:
    c = v.counts
    return (f"SEQ={v.seq:08X} CMD={v.cmd:04X} MAC={int(v.mac_ok)} STR={int(v.strict_accept)} "
            f"WIN={int(v.window_accept)} WR={v.window_reason} POL={v.policy} "
            f"RES={'ACC' if v.final_accept else 'REJ'} DOOR={'O' if v.door_open else 'C'} "
            f"LAT=???? CNT=???? SC={c.sc_acc % 10000:04d}/{c.sc_rej % 10000:04d} "
            f"SW={c.sw_acc % 10000:04d}/{c.sw_rej % 10000:04d}")


RESET_RE = re.compile(r"^RST EPOCH=([0-9A-F]{8}) POL=(SC|SW)$")


def expected_reset_line(r: ResetResult, policy: str) -> str:
    return f"RST EPOCH={r.epoch:08X} POL={policy}" if r.accepted else "RST DENIED"


def reset_policy(line: str) -> str | None:
    m = RESET_RE.match(line.strip())
    return m.group(2) if m else None


def matches(line: str, expected: str) -> bool:
    return len(line) == len(expected) and all(e in ("?", g) for g, e in zip(line, expected))


def parse_verdict(line: str) -> dict | None:
    m = VERDICT_RE.match(line.strip())
    if not m:
        return None
    g = m.groups()
    return {"seq": int(g[0], 16), "cmd": int(g[1], 16), "mac_ok": g[2] == "1",
            "strict_accept": g[3] == "1", "window_accept": g[4] == "1", "window_reason": g[5],
            "policy": g[6], "final_accept": g[7] == "ACC", "door_open": g[8] == "O",
            "latency_cycles": int(g[9], 16), "count": int(g[10], 16)}
