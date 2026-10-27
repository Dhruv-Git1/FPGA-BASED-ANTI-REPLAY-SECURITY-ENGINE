"""Checks for the Python golden models. Run with: python -m pytest tests"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "host"))

from packet import (CMD_CLOSE, CMD_OPEN, forge_reset, make_packet, make_reset,  # noqa: E402
                    tamper_device, tamper_payload, tamper_tag)
from replay_model import AntiReplayModel, DUP, INW, NEW, STL, AUT, SC, SW  # noqa: E402
from scenarios import (auth_failure_isolation, normal_out_of_order_duplicate,  # noqa: E402
                       reset_attacks, replayed_command, stale, window_edges)
from session import SessionDriver  # noqa: E402
from siphash import siphash24  # noqa: E402

# First 16 entries of vectors_sip64 from https://github.com/veorq/SipHash/blob/master/vectors.h
# Key 00..0f, message for entry i is bytes 00..(i-1).
OFFICIAL = [
    "310e0edd47db6f72", "fd67dc93c539f874", "5a4fa9d909806c0d", "2d7efbd796666785",
    "b7877127e09427cf", "8da699cd64557618", "cee3fe586e46c9cb", "37d1018bf50002ab",
    "6224939a79f5f593", "b0e4a90bdf82009e", "f3b9dd94c5bb5d7a", "a7ad6b22462fb3f4",
    "fbe50e86bc8f1e75", "903d84c02756ea14", "eef27a8e90ca23f7", "e545be4961ca29a1",
]


@pytest.mark.parametrize("i", range(16))
def test_siphash_official_vectors(i):
    assert siphash24(bytes(range(16)), bytes(range(i))).hex() == OFFICIAL[i]


def verdicts(steps, w, policy=SC):
    model = AntiReplayModel(w, policy)
    out = []
    for s in steps:
        if isinstance(s, str):
            model.button_reset()
        else:
            v = model.process(s)
            out.append((v.mac_ok, v.strict_accept, v.window_accept, v.window_reason, v.final_accept))
    return out


def test_spec_rows_1_to_4():
    assert verdicts(normal_out_of_order_duplicate(), 64, SW) == [
        (True, True, True, NEW, True),     # 1
        (True, True, True, NEW, True),     # 2
        (True, False, True, NEW, True),    # 4: strict rejects, window accepts
        (True, True, True, INW, True),     # 3: both accept
        (True, False, False, DUP, False),  # 3 again: both reject
    ]


def test_final_verdict_follows_policy():
    steps = normal_out_of_order_duplicate()
    assert [v[4] for v in verdicts(steps, 64, SC)] == [True, True, False, True, False]
    assert [v[4] for v in verdicts(steps, 64, SW)] == [True, True, True, True, False]


def test_auth_failure_leaves_state_unchanged():
    model = AntiReplayModel(32)
    model.process(make_packet(1))
    before = (model.strict.expected_seq, model.window.state())
    for bad in (tamper_payload(make_packet(2)), tamper_tag(make_packet(2)),
                tamper_device(make_packet(2)), tamper_tag(make_packet(999))):
        v = model.process(bad)
        assert (v.mac_ok, v.strict_accept, v.window_accept, v.window_reason, v.final_accept) == \
            (False, False, False, AUT, False)
        assert (model.strict.expected_seq, model.window.state()) == before


def test_auth_isolation_scenario():
    assert verdicts(auth_failure_isolation(), 32)[-1] == (True, True, True, NEW, True)


def test_failed_first_packet_does_not_initialize_window():
    model = AntiReplayModel(32)
    model.process(tamper_tag(make_packet(500)))
    assert model.window.state() == (False, 0, 0)


def test_replayed_open_does_not_reopen():
    model = AntiReplayModel(64, SW)
    states = [model.process(p).door_open for p in replayed_command() if not isinstance(p, str)]
    assert states == [True, False, False]


def test_counters_per_engine():
    model = AntiReplayModel(64, SW)
    for p in normal_out_of_order_duplicate()[1:]:
        v = model.process(p)
    assert (v.counts.sc_acc, v.counts.sc_rej, v.counts.sw_acc, v.counts.sw_rej) == (3, 2, 4, 1)


def test_signed_reset_rules():
    model = AntiReplayModel(64)
    model.process(make_packet(1))
    assert not model.process_reset(forge_reset(5)).accepted        # wrong tag
    assert model.strict.expected_seq == 2
    assert model.process_reset(make_reset(5)).accepted
    assert model.strict.expected_seq == 1
    assert not model.process_reset(make_reset(5)).accepted         # same epoch again
    assert not model.process_reset(make_reset(4)).accepted         # older epoch
    assert model.process_reset(make_reset(6)).accepted


def test_data_tag_never_passes_as_reset():
    # Same 8 message bytes, different key: the tags differ.
    data = make_packet(7, device_id=0, payload=0)
    assert data.tag != make_reset(7).tag


def test_reset_attack_scenario_rejects_old_packet():
    drv = SessionDriver(64, SW)
    lines = [x.expected for s in reset_attacks() for x in drv.expand(s)]
    assert lines[0].startswith("RST EPOCH=00000001")
    assert lines.count("RST DENIED") == 3
    replays = [ln for ln in lines if ln.startswith("SEQ=00000001")][1:]
    assert len(replays) == 3 and all("RES=REJ" in ln and "WR=DUP" in ln for ln in replays)


@pytest.mark.parametrize("w", [16, 32, 64, 128])
def test_stale(w):
    assert verdicts(stale(w), w)[-1] == (True, False, False, STL, False)


@pytest.mark.parametrize("w", [16, 32, 64, 128])
def test_window_edges(w):
    reasons = [r[3] for r in verdicts(window_edges(w), w)]
    assert reasons == [NEW, INW, DUP, STL, NEW, STL, INW, NEW, DUP]


def test_door_and_commands_only_on_accept():
    model = AntiReplayModel(64, SC)
    assert model.process(make_packet(2, payload=CMD_OPEN)).door_open is False  # strict rejects 2
    assert model.process(make_packet(1, payload=CMD_OPEN)).door_open is True
    assert model.process(tamper_tag(make_packet(2, payload=CMD_CLOSE))).door_open is True
