"""Offline tests for the RCON client and bridge against a fake Factorio RCON
server that answers like 2.0.77 (one packet per reply, possibly preceded by
unrelated packets) and serves chunked envelopes."""

import asyncio
import json
import re
import struct

import pytest

from factorio_mcp.bridge import Bridge, ModError, escape_lua_string
from factorio_mcp.rcon import RconClient, RconError


class FakeFactorio:
    """Minimal Source-RCON server. `handler(method, params) -> envelope dict`."""

    def __init__(self, handler, password="pw", noise=True, drop_first=0):
        self.handler, self.password, self.noise = handler, password, noise
        self.drop_first = drop_first  # close the connection on the first N commands, without replying
        self.commands: list[str] = []
        self.server = None

    async def start(self):
        self.server = await asyncio.start_server(self._client, "127.0.0.1", 0)
        return self.server.sockets[0].getsockname()[1]

    async def stop(self):
        self.server.close()
        await self.server.wait_closed()

    @staticmethod
    def _packet(req_id, kind, body: bytes):
        payload = struct.pack("<ii", req_id, kind) + body + b"\x00\x00"
        return struct.pack("<i", len(payload)) + payload

    async def _client(self, reader, writer):
        try:
            while True:
                (size,) = struct.unpack("<i", await reader.readexactly(4))
                data = await reader.readexactly(size)
                req_id, kind = struct.unpack("<ii", data[:8])
                body = data[8:-2].decode()
                if kind == 3:
                    writer.write(self._packet(req_id if body == self.password else -1, 2, b""))
                else:
                    self.commands.append(body)
                    if self.drop_first > 0:
                        self.drop_first -= 1
                        writer.close()
                        return
                    if self.noise:  # a reply to some other id must be ignored
                        writer.write(self._packet(req_id + 1000, 0, b"stray"))
                    writer.write(self._packet(req_id, 0, self._respond(body).encode()))
                await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionResetError):
            pass

    def _respond(self, cmd: str) -> str:
        m = re.match(r'/silent-command remote\.call\("factorio_mcp","rpc","(\w+)","(.*)"\)$', cmd)
        if not m:
            return "unknown command"
        params = json.loads(m.group(2).replace('\\"', '"').replace("\\\\", "\\"))
        return json.dumps(self.handler(m.group(1), params))


@pytest.fixture
async def fake():
    servers = []

    async def make(handler, **kw):
        f = FakeFactorio(handler, **kw)
        port = await f.start()
        servers.append(f)
        return f, port

    yield make
    for f in servers:
        await f.stop()


def test_escape_lua_string():
    assert escape_lua_string('{"a":"b\\\\c"}') == '{\\"a\\":\\"b\\\\\\\\c\\"}'


async def test_large_reply_and_stray_packets(fake):
    big = "x" * 50000
    f, port = await fake(lambda m, p: {"ok": True, "data": {"blob": big}})
    b = Bridge(RconClient("127.0.0.1", port, "pw"), "scout-1", "session-1234")
    data = await b.call("get_state", {})
    assert data["blob"] == big


async def test_scoped_calls_carry_character_and_session(fake):
    seen = {}

    def handler(method, params):
        seen[method] = params
        return {"ok": True, "data": {}}

    f, port = await fake(handler)
    b = Bridge(RconClient("127.0.0.1", port, "pw"), "scout-1", "session-1234")
    await b.call("get_state", {"radius": 10})
    await b.call("ping")
    assert seen["get_state"] == {"radius": 10, "companion": "scout-1", "session": "session-1234"}
    assert "companion" not in seen["ping"] and "session" not in seen["ping"]


async def test_chunked_envelope(fake):
    full = json.dumps({"ok": True, "data": {"text": "hello " * 1000}})
    parts = [full[i:i + 1000] for i in range(0, len(full), 1000)]

    def handler(method, params):
        if method == "get_chunk":
            return {"ok": True, "data": {"data": parts[params["part"] - 1]}}
        return {"ok": True, "chunked": True, "id": 7, "parts": len(parts), "data": parts[0]}

    f, port = await fake(handler)
    b = Bridge(RconClient("127.0.0.1", port, "pw"), "scout-1")
    data = await b.call("scan_area", {})
    assert data["text"] == "hello " * 1000


async def test_mod_errors_surface(fake):
    f, port = await fake(lambda m, p: {"ok": False, "error": "no such item"})
    b = Bridge(RconClient("127.0.0.1", port, "pw"), "scout-1")
    with pytest.raises(ModError, match="no such item"):
        await b.call("inspect", {})


async def test_wrong_password(fake):
    f, port = await fake(lambda m, p: {"ok": True})
    with pytest.raises(RconError, match="auth failed"):
        await RconClient("127.0.0.1", port, "nope").connect()


async def test_wait_job_never_cancels(fake):
    calls = []

    def handler(method, params):
        calls.append(method)
        return {"ok": True, "data": {"status": "running", "type": "walk_to", "detail": ""}}

    f, port = await fake(handler)
    b = Bridge(RconClient("127.0.0.1", port, "pw"), "scout-1")
    res = await b.wait_job(3, timeout_s=0.3, poll_s=0.1)
    assert res.status == "running" and not res.finished
    assert "cancel" not in calls


async def test_concurrent_clients_do_not_mix_replies(fake):
    def handler(method, params):
        return {"ok": True, "data": {"who": params.get("companion")}}

    f, port = await fake(handler)
    bridges = [Bridge(RconClient("127.0.0.1", port, "pw"), f"agent-{i}") for i in range(8)]

    async def run(b):
        return [ (await b.call("get_state"))["who"] for _ in range(10)]

    results = await asyncio.gather(*(run(b) for b in bridges))
    for i, r in enumerate(results):
        assert r == [f"agent-{i}"] * 10


async def test_lost_binding_rebinds_and_retries_once(fake):
    state = {"bound": False, "calls": 0}

    def handler(method, params):
        if method == "get_state":
            state["calls"] += 1
            if not state["bound"]:
                return {"ok": False, "error": "this MCP session does not hold character 'scout-1'"}
            return {"ok": True, "data": {"fine": True}}
        return {"ok": True, "data": {}}

    f, port = await fake(handler)
    b = Bridge(RconClient("127.0.0.1", port, "pw"), "scout-1", "session-1234")

    async def rebind():
        state["bound"] = True

    b.rebind = rebind
    assert (await b.call("get_state"))["fine"] is True
    assert state["calls"] == 2  # one refused, one after re-binding


async def test_dropped_connection_retries_safe_calls_only(fake, monkeypatch):
    import factorio_mcp.bridge as bridge_mod
    monkeypatch.setattr(bridge_mod, "RETRY_DELAYS_S", (0.01, 0.01))
    f, port = await fake(lambda m, p: {"ok": True, "data": {"m": m}}, drop_first=1)
    b = Bridge(RconClient("127.0.0.1", port, "pw", timeout_s=2), "scout-1", "session-1234")
    assert (await b.call("get_state"))["m"] == "get_state"  # read-only: retried after the drop

    f2, port2 = await fake(lambda m, p: {"ok": True, "data": {}}, drop_first=1)
    b2 = Bridge(RconClient("127.0.0.1", port2, "pw", timeout_s=2), "scout-1", "session-1234")
    with pytest.raises(ModError, match="may or may not have run"):
        await b2.call("say", {"text": "hi"})  # has side effects: not repeated blindly


async def test_enqueue_carries_a_request_id(fake):
    seen = {}

    def handler(method, params):
        seen.update(params)
        return {"ok": True, "data": {"task_id": 1}}

    f, port = await fake(handler)
    b = Bridge(RconClient("127.0.0.1", port, "pw"), "scout-1", "session-1234")
    await b.enqueue({"type": "walk_to"})
    assert len(seen.get("request_id", "")) == 32
