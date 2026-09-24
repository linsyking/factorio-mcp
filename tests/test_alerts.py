"""Offline tests for the 0.2.19 plumbing: ambient ALERTS lines (mod 0.2.19+
attaches them to scoped responses; the bridge collects, the tool wrappers
render) and the client-side mod-version gating (the pick_up skew class)."""

from __future__ import annotations

import json

import pytest
from mcp.server.mcpserver.exceptions import ToolError

from factorio_mcp import tools as T
from factorio_mcp.bridge import Bridge, ModError
from factorio_mcp.game import Config, parse_version

LINE = "ALERTS: no-power 3 (+3 since your last call)"


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


# ------------------------------------------------------------------- bridge

async def test_alert_line_collected_and_drained():
    b = Bridge(FakeRcon(env(data={"a": 1}, alerts=LINE)), "agent")
    assert await b.call("get_state", {}) == {"a": 1}
    assert b.drain_alerts() == [LINE]
    assert b.drain_alerts() == []


async def test_no_alerts_no_noise():
    b = Bridge(FakeRcon(env(data={})), "agent")
    await b.call("get_state", {})
    assert b.drain_alerts() == []


async def test_alert_line_collected_on_error_envelopes():
    line = "ALERTS: no-fuel 2 (+2 since your last call)"
    b = Bridge(FakeRcon(env(error="boom", alerts=line)), "agent")
    with pytest.raises(ModError, match="boom"):
        await b.call("mine", {})
    assert b.drain_alerts() == [line]


async def test_alert_line_survives_chunking():
    line = "ALERTS: no-power 9 (+9 since your last call)"
    full = env(data={"big": "x" * 4000}, alerts=line)
    first = json.dumps({"ok": True, "chunked": True, "id": 7, "parts": 2, "data": full[:3400]})
    second = json.dumps({"ok": True, "data": {"data": full[3400:]}})  # get_chunk returns {data: part}
    b = Bridge(FakeRcon(first, second), "agent")
    r = await b.call("scan_area", {})
    assert r["big"] == "x" * 4000
    assert b.drain_alerts() == [line]


async def test_unscoped_methods_collect_nothing():
    b = Bridge(FakeRcon(env(alerts=LINE)), "agent")
    await b.call("ping")
    assert b.drain_alerts() == []


# ------------------------------------------------------------- tool wrappers

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


async def test_inbox_tool_gets_alerts_line():
    rcon = FakeRcon(
        env(data={"status": "building"}, alerts=LINE),   # set_status
        env(data={"messages": [], "last_id": 4}),        # inbox: read_chat
        env(data={"events": []}),                        # inbox: read_events
    )
    out = await registered(Bridge(rcon, "agent")).registry["set_status"]("building")
    assert out.startswith("Status: building")
    assert out.endswith("\n\n" + LINE)


async def test_no_inbox_tool_still_gets_alerts():
    rcon = FakeRcon(env(data={"messages": [], "last_id": 9}, alerts=LINE))
    out = await registered(Bridge(rcon, "agent")).registry["read_chat"]()
    assert out.startswith("No new chat")
    assert out.endswith("\n\n" + LINE)


async def test_alerts_independent_of_the_inbox_flag():
    rcon = FakeRcon(env(data={"cleared": True}, alerts=LINE))
    out = await registered(Bridge(rcon, "agent"), inbox=False).registry["set_status"]("")
    assert out == "Status cleared.\n\n" + LINE


async def test_tool_error_carries_alerts():
    rcon = FakeRcon(env(error="kaput", alerts=LINE))
    with pytest.raises(ToolError) as ei:
        await registered(Bridge(rcon, "agent")).registry["set_status"]("x")
    assert LINE in str(ei.value)


# ------------------------------------------------------------------- gating

def test_parse_version():
    assert parse_version("0.2.19") == (0, 2, 19)
    assert parse_version("1.2.3-dev") == (1, 2, 3)
    assert parse_version("nope") is None
    assert parse_version("2.0") is None
    assert parse_version(None) is None
    assert parse_version(7) is None


def test_gated_tools():
    names = ["pick_up", "walk_to", "scan_area"]
    assert T.gated_tools(names, (0, 2, 17)) == ["pick_up"]
    assert T.gated_tools(names, (0, 2, 18)) == []
    assert T.gated_tools(names, (0, 2, 19)) == []
    assert T.gated_tools(names, None) == []
    assert T.gated_tools(["anything"], None) == []


class FakeVersionGame:
    def __init__(self, v):
        self.mod_version = v

    async def probe_mod_version(self):
        return self.mod_version


async def test_call_tool_gate_blocks_too_new_tool():
    from factorio_mcp.server import StrictMCPServer

    app = StrictMCPServer(name="t", version="0", game=FakeVersionGame((0, 2, 17)))
    with pytest.raises(ToolError, match=r"pick_up needs mod 0\.2\.18\+.*runs factorio-mcp 0\.2\.17"):
        await app.call_tool("pick_up", {})


async def test_call_tool_gate_passes_when_mod_is_new_enough():
    from factorio_mcp.server import StrictMCPServer

    app = StrictMCPServer(name="t", version="0", game=FakeVersionGame((0, 2, 18)))
    with pytest.raises(Exception) as ei:  # not registered on this bare server
        await app.call_tool("pick_up", {})
    assert "needs mod" not in str(ei.value)


async def test_list_tools_filters_gated():
    from factorio_mcp.server import StrictMCPServer

    app = StrictMCPServer(name="t", version="0", game=FakeVersionGame((0, 2, 17)))

    @app.tool(name="pick_up", description="d")
    async def pick_up(): ...

    @app.tool(name="walk_to", description="d")
    async def walk_to(): ...

    names = [t.name for t in await app.list_tools()]
    assert "pick_up" not in names
    assert "walk_to" in names


async def test_list_tools_advertises_all_when_version_unknown():
    from factorio_mcp.server import StrictMCPServer

    app = StrictMCPServer(name="t", version="0", game=FakeVersionGame(None))

    @app.tool(name="pick_up", description="d")
    async def pick_up(): ...

    names = [t.name for t in await app.list_tools()]
    assert "pick_up" in names  # no information -> no gating (status quo)
