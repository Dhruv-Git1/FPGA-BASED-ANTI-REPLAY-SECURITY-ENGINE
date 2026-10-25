"""Checks for the Python golden models. Run with: python -m pytest tests"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "host"))

from packet import make_packet, tamper_payload, tamper_tag  # noqa: E402
from replay_model import AntiReplayModel, DUP, INW, NEW, STL, AUT  # noqa: E402
from scenarios import (auth_failure_isolation, normal_out_of_order_duplicate,  # noqa: E402
                       stale, window_edges)
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


def run(steps, w):
    model = AntiReplayModel(w)
    out = []
    for s in steps:
        if s == "reset":
            model.reset()
        else:
            v = model.process(s)
            out.append((v.mac_ok, v.strict_accept, v.window_accept, v.window_reason))
    return out


def test_spec_rows_1_to_4():
    assert run(normal_out_of_order_duplicate(), 64) == [
        (True, True, True, NEW),    # 1
        (True, True, True, NEW),    # 2
        (True, False, True, NEW),   # 4: strict rejects, window accepts
        (True, True, True, INW),    # 3: both accept
        (True, False, False, DUP),  # 3 again: both reject
    ]


def test_auth_failure_leaves_state_unchanged():
    model = AntiReplayModel(32)
    model.process(make_packet(1))
    before = (model.strict.expected_seq, model.window.state())
    for bad in (tamper_payload(make_packet(2)), tamper_tag(make_packet(2)),
                tamper_tag(make_packet(999))):
        v = model.process(bad)
        assert (v.mac_ok, v.strict_accept, v.window_accept, v.window_reason) == \
            (False, False, False, AUT)
        assert (model.strict.expected_seq, model.window.state()) == before


def test_auth_isolation_scenario():
    assert run(auth_failure_isolation(), 32)[-1] == (True, True, True, NEW)


def test_failed_first_packet_does_not_initialize_window():
    model = AntiReplayModel(32)
    model.process(tamper_tag(make_packet(500)))
    assert model.window.state() == (False, 0, 0)


@pytest.mark.parametrize("w", [16, 32, 64, 128])
def test_stale(w):
    assert run(stale(w), w)[-1] == (True, False, False, STL)


@pytest.mark.parametrize("w", [16, 32, 64, 128])
def test_window_edges(w):
    reasons = [r[3] for r in run(window_edges(w), w)]
    assert reasons == [NEW, INW, DUP, STL, NEW, STL, INW, NEW, DUP]
