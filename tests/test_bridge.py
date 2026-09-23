"""Offline tests for the RCON client and bridge against a fake Factorio RCON
server that splits responses into several packets and serves chunked envelopes."""

import asyncio
import json
import re
import struct

import pytest

from factorio_mcp.bridge import Bridge, ModError, escape_lua_string
from factorio_mcp.rcon import RconClient, RconError


class FakeFactorio:
    """Minimal Source-RCON server. `handler(method, params) -> envelope dict`."""

    def __init__(self, handler, password="pw", split=700):
        self.handler, self.password, self.split = handler, password, split
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
                elif body == " ":
                    writer.write(self._packet(req_id, 0, b""))  # sentinel reply
                else:
                    self.commands.append(body)
                    out = self._respond(body).encode()
                    for i in range(0, max(len(out), 1), self.split):  # multi-packet response
                        writer.write(self._packet(req_id, 0, out[i:i + self.split]))
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


async def test_multi_packet_response_is_reassembled(fake):
    big = "x" * 5000
    f, port = await fake(lambda m, p: {"ok": True, "data": {"blob": big}}, split=500)
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

    f, port = await fake(handler, split=64)
    bridges = [Bridge(RconClient("127.0.0.1", port, "pw"), f"agent-{i}") for i in range(8)]

    async def run(b):
        return [ (await b.call("get_state"))["who"] for _ in range(10)]

    results = await asyncio.gather(*(run(b) for b in bridges))
    for i, r in enumerate(results):
        assert r == [f"agent-{i}"] * 10
