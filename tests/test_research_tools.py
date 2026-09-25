"""Offline tests for the 0.2.21 tech-tree tools (row #74): list_technologies
rendering (statuses, live queue, bills) and cancel_research reporting, plus
the client-side gating that holds both back against older mods."""

from __future__ import annotations

import json

from factorio_mcp import tools as T
from factorio_mcp.bridge import Bridge
from factorio_mcp.game import Config


class FakeRcon:
    def __init__(self, *replies):
        self.replies = list(replies)
        self.commands = []

    async def exec(self, cmd):
        self.commands.append(cmd)
        if not self.replies:
            raise AssertionError("unexpected RCON command: " + cmd)
        return self.replies.pop(0)

    def close(self):
        pass


def env(data=None, error=None, alerts=None):
    e = {"ok": error is None}
    if error is not None:
        e["error"] = error
    else:
        e["data"] = data if data is not None else {}
    if alerts:
        e["alerts"] = alerts
    return json.dumps(e)


class FakeApp:
    def __init__(self):
        self.registry = {}

    def tool(self, name=None, description=None):
        def deco(fn):
            self.registry[name] = fn
            return fn

        return deco


class FakeGame:
    def __init__(self, bridge, inbox=True):
        self.cfg = Config(inbox=inbox)
        self._bridge = bridge

    def take_notice(self):
        return ""

    async def bridge(self):
        return self._bridge

    async def call(self, method, params=None):
        return await self._bridge.call(method, params)

    def drain_alerts(self):
        return self._bridge.drain_alerts()

    def new_queue(self):
        pass


def registered(bridge, inbox=True):
    app, game = FakeApp(), FakeGame(bridge, inbox=inbox)
    T.register(app, game)
    return app


TREE = {
    "filter": "available",
    "search": None,
    "current": "logistics-2",
    "progress": 40,
    "queue": ["logistics-2", "oil-processing"],
    "counts": {"researched": 24, "in-progress": 1, "queued": 1, "available": 3, "trigger": 2, "locked": 12},
    "techs": [
        {"name": "fast-inserter", "label": "Fast inserter", "status": "available", "level": 1,
         "infinite": False, "prereqs": ["steel-processing"], "missing": ["steel-processing"],
         "bill": {"automation-science-pack": 75, "logistic-science-pack": 75},
         "unit_energy": 900, "unit_time_s": 15},
        {"name": "mining-productivity-bonus-1", "label": "Mining productivity bonus 1", "status": "available",
         "level": 3, "infinite": True, "prereqs": [], "missing": [],
         "bill": {"automation-science-pack": 250}, "unit_energy": 600, "unit_time_s": 10},
    ],
}


async def test_list_technologies_renders():
    rcon = FakeRcon(env(data=TREE))
    out = await registered(Bridge(rcon, "agent"), inbox=False).registry["list_technologies"]()
    assert "Research in progress: logistics-2 (40% done)." in out
    assert "Queue: logistics-2 -> oil-processing." in out
    assert "available 3, trigger 2, locked 12" in out
    assert "Showing 2 with status available:" in out
    assert "fast-inserter (Fast inserter): missing steel-processing; " \
           "bill 75 automation-science-pack + 75 logistic-science-pack; 15s/unit at one lab (speed 1)" in out
    assert "mining-productivity-bonus-1 (Mining productivity bonus 1): level 3, infinite; " \
           "bill 250 automation-science-pack; 10s/unit at one lab (speed 1)" in out


async def test_list_technologies_defaults_to_no_params():
    rcon = FakeRcon(env(data=TREE))
    await registered(Bridge(rcon, "agent"), inbox=False).registry["list_technologies"]()
    cmd = rcon.commands[0]
    assert "list_technologies" in cmd
    assert '"status"' not in cmd and '"search"' not in cmd


async def test_list_technologies_passes_filters():
    rcon = FakeRcon(env(data=dict(TREE, filter="all", search="fast")))
    await registered(Bridge(rcon, "agent"), inbox=False).registry["list_technologies"](status="all", search="fast")
    assert r'\"status\":\"all\"' in rcon.commands[0] and r'\"search\":\"fast\"' in rcon.commands[0]


async def test_list_technologies_with_inbox_footer():
    rcon = FakeRcon(
        env(data=TREE),                                  # list_technologies
        env(data={"messages": [], "last_id": 4}),        # inbox: read_chat
        env(data={"events": []}),                        # inbox: read_events
    )
    out = await registered(Bridge(rcon, "agent")).registry["list_technologies"]()
    assert "Research in progress: logistics-2 (40% done)." in out


async def test_cancel_research_renders():
    rcon = FakeRcon(env(data={"removed": "oil-processing", "queue": ["logistics-2"]}))
    out = await registered(Bridge(rcon, "agent"), inbox=False).registry["cancel_research"]("oil-processing")
    assert out == "Removed oil-processing from the research queue. Queue now: logistics-2."


async def test_cancel_research_reports_dropped_and_note():
    rcon = FakeRcon(env(data={"removed": "oil-processing", "queue": ["logistics-2"],
                              "dropped": ["fast-inserter"],
                              "note": "research progress restored after the queue rewrite"}))
    out = await registered(Bridge(rcon, "agent"), inbox=False).registry["cancel_research"]("oil-processing")
    assert "WARNING: the engine dropped fast-inserter from the queue as well." in out
    assert "(research progress restored after the queue rewrite)" in out


def test_gating_holds_back_0_2_21_tools():
    names = ["pick_up", "list_technologies", "cancel_research", "walk_to"]
    assert T.gated_tools(names, (0, 2, 20)) == ["cancel_research", "list_technologies"]
    assert T.gated_tools(names, (0, 2, 21)) == []
    assert T.gated_tools(names, None) == []
