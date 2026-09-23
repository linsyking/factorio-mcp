"""Typed wrapper over RCON -> remote.call("factorio_mcp", "rpc", ...).

One Bridge = one MCP instance = one bound character. Every scoped call carries
{companion: <character>, session: <token>}; the mod checks the binding.
See docs/PROTOCOL.md.
"""

from __future__ import annotations

import asyncio
import json
import time
import uuid
from dataclasses import dataclass
from typing import Any

from .rcon import RconClient, RconError

PROTOCOL_VERSION = 5
UNSCOPED = {"ping", "echo", "get_chunk", "bind"}
TERMINAL = {"done", "failed", "cancelled"}


class ModError(Exception):
    """An error reported by the game side (or a protocol failure)."""


def escape_lua_string(s: str) -> str:
    # JSON output never contains raw control characters, so escaping
    # backslash and double quote is enough for a double-quoted Lua string.
    return s.replace("\\", "\\\\").replace('"', '\\"')


def parse_envelope(raw: str) -> dict[str, Any]:
    try:
        env = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ModError(f"invalid protocol response from the game: {raw[:200]!r}") from e
    if not isinstance(env, dict) or "ok" not in env:
        raise ModError(f"invalid protocol envelope: {raw[:200]!r}")
    return env


@dataclass
class JobResult:
    job_id: int
    type: str
    status: str  # queued | running | done | failed | cancelled
    detail: str

    @property
    def finished(self) -> bool:
        return self.status in TERMINAL


class Bridge:
    def __init__(self, rcon: RconClient, character: str, session: str | None = None):
        self.rcon = rcon
        self.character = character
        self.session = session or uuid.uuid4().hex

    # ------------------------------------------------------------ transport

    async def call(self, method: str, params: dict[str, Any] | None = None) -> Any:
        body = dict(params or {})
        if method not in UNSCOPED:
            body["companion"] = self.character
            body["session"] = self.session
        payload = escape_lua_string(json.dumps(body, separators=(",", ":")))
        cmd = f'/silent-command remote.call("factorio_mcp","rpc","{method}","{payload}")'
        try:
            raw = (await self.rcon.exec(cmd)).strip()
        except RconError as e:
            raise ModError(str(e)) from e
        if not raw:
            raise ModError(
                "empty response from the game — is the factorio-mcp mod installed and enabled on the server?"
            )
        env = parse_envelope(raw)
        if env.get("ok") and env.get("chunked"):
            assembled = env["data"]
            for part in range(2, int(env["parts"]) + 1):
                chunk = await self.call("get_chunk", {"id": env["id"], "part": part})
                assembled += chunk["data"]
            env = parse_envelope(assembled)
        if not env.get("ok"):
            raise ModError(str(env.get("error") or "unknown mod error"))
        return env.get("data") or {}

    async def unlock(self) -> dict[str, Any]:
        """The first Lua command on a fresh save returns nothing (Factorio's
        achievements warning). Send a harmless ping up to twice to get past it."""
        last: Exception | None = None
        for _ in range(2):
            try:
                return await self.call("ping")
            except ModError as e:
                if "empty response" not in str(e):
                    raise
                last = e
        raise ModError(
            "the game did not accept Lua commands — is the factorio-mcp mod installed and enabled?"
        ) from last

    async def connect_and_bind(self, takeover: bool = False) -> dict[str, Any]:
        ping = await self.unlock()
        if ping.get("protocol_version") != PROTOCOL_VERSION:
            raise ModError(
                f"protocol mismatch: mod speaks v{ping.get('protocol_version')}, this server v{PROTOCOL_VERSION}"
                " — install the matching factorio-mcp mod version on the game server"
            )
        body = await self.call(
            "bind", {"name": self.character, "session": self.session, "takeover": takeover}
        )
        return {"ping": ping, "body": body}

    # ----------------------------------------------------------------- jobs

    async def enqueue(
        self,
        task: dict[str, Any],
        *,
        replace: bool = False,
        quiet: bool = False,
        chain: str | None = None,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {"task": task, "replace": replace, "quiet": quiet}
        if chain:
            params["chain"] = chain
        return await self.call("enqueue", params)

    async def job(self, job_id: int) -> JobResult:
        st = await self.call("get_task", {"task_id": job_id})
        return JobResult(job_id, str(st.get("type") or "?"), str(st.get("status")), str(st.get("detail") or ""))

    async def wait_job(self, job_id: int, timeout_s: float, poll_s: float = 0.5) -> JobResult:
        """Polls until the job finishes or timeout_s passes. Never cancels."""
        deadline = time.monotonic() + max(0.0, timeout_s)
        res = await self.job(job_id)
        while not res.finished and time.monotonic() < deadline:
            await asyncio.sleep(min(poll_s, max(0.05, deadline - time.monotonic())))
            res = await self.job(job_id)
        return res

    # --------------------------------------------------------- chat/events

    # The read cursors live in the mod, per character: a new MCP session for
    # the same character continues where the previous one stopped reading.
    async def read_chat(self, since_id: int | None = None) -> dict[str, Any]:
        return await self.call("get_chat", {} if since_id is None else {"since_id": since_id})

    async def read_events(self, since_id: int | None = None) -> dict[str, Any]:
        return await self.call("get_events", {} if since_id is None else {"since_id": since_id})


def as_list(v: Any) -> list[Any]:
    """Factorio serializes empty tables as {} — normalize to a list."""
    if isinstance(v, list):
        return v
    if isinstance(v, dict) and not v:
        return []
    if isinstance(v, dict):
        return list(v.values())
    return []
