"""Offline tests for the restart-rollback detection (game.py, 0.2.17): a bind
whose server tick is BELOW the last tick this character saw means the game
rolled back — cancel whatever the save resurrected, start a fresh chain, and
queue the agent notice. The wedge class that stalled coal's lane through the
0.2.16 deploy."""
import asyncio
import json

import pytest

from factorio_mcp.bridge import ModError
from factorio_mcp.game import Config, Game


class StubBridge:
    def __init__(self):
        self.calls = []
        self.fail = False

    async def call(self, method, params=None, _rebound=False):
        self.calls.append((method, params))
        if self.fail:
            raise ModError("rcon down")
        return {"cancelled": 3}


@pytest.fixture
def state_file(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path))
    return tmp_path / "factorio-mcp" / "queues.json"


def make_game():
    g = Game(Config(character="coal"))
    g._bridge = StubBridge()
    return g


def entry(path):
    return json.loads(path.read_text())["127.0.0.1:27015/coal"]


def test_old_state_format_migrates(state_file):
    state_file.parent.mkdir(parents=True)
    state_file.write_text(json.dumps({"127.0.0.1:27015/coal": "coal:old-chain"}))
    g = make_game()
    assert g.queue == "coal:old-chain"  # the chain carries over
    g._note_tick(100)
    assert entry(state_file) == {"chain": "coal:old-chain", "last_tick": 100}
    g._note_tick(50)  # ticks only move forward in a running game
    assert entry(state_file)["last_tick"] == 100


def test_forward_tick_is_not_a_restart(state_file):
    g = make_game()
    g.new_queue()
    g._note_tick(200)
    assert g.take_notice() == ""
    asyncio.run(g._check_restart(210))
    assert g.take_notice() == ""
    assert entry(state_file)["last_tick"] == 210
    assert g._bridge.calls == []  # nothing was cancelled
    assert g.queue  # the chain is untouched


def test_tick_regression_resynthesizes(state_file):
    g = make_game()
    g.new_queue()
    old_chain = g.queue
    g._note_tick(300)
    asyncio.run(g._check_restart(250))  # rolled back to an older autosave
    assert ("cancel", {"all": True}) in g._bridge.calls  # the resurrected lane dies
    state = entry(state_file)
    assert state["chain"] != old_chain  # fresh chain, no wedge
    assert state["last_tick"] == 250  # the timeline re-baselines
    notice = g.take_notice()
    assert "rolled back" in notice and "resubmit" in notice
    assert g.take_notice() == ""  # one-shot


def test_rebaseline_stops_re_detecting(state_file):
    g = make_game()
    g.new_queue()
    g._note_tick(300)
    asyncio.run(g._check_restart(250))
    assert g.take_notice()  # consumed here, as a tool result would
    g._bridge.calls.clear()
    asyncio.run(g._check_restart(260))  # the game runs on from the rollback
    assert g._bridge.calls == []
    assert g.take_notice() == ""


def test_cancel_failure_still_unwedges_the_chain(state_file):
    g = make_game()
    g.new_queue()
    old_chain = g.queue
    g._note_tick(400)
    g._bridge.fail = True
    asyncio.run(g._check_restart(100))
    state = entry(state_file)
    assert state["chain"] != old_chain and state["last_tick"] == 100
    notice = g.take_notice()
    assert "rolled back" in notice and "stale lane" not in notice
