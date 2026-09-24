"""Connection manager: one RCON connection, one bound character, one session.

Connects lazily (the MCP server starts even when the game is down), binds the
configured character on first use, and keeps the binding lease alive with a
heartbeat while idle.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .bridge import Bridge, ModError
from .rcon import RconClient

log = logging.getLogger("factorio_mcp")

HEARTBEAT_S = 20.0


@dataclass
class Config:
    host: str = "127.0.0.1"
    port: int = 27015
    password: str = ""
    character: str = "agent"
    takeover: bool = False
    default_wait_s: float = 0.0  # 0 = job tools queue and return at once
    rcon_timeout_s: float = 15.0
    inbox: bool = True  # append unread chat to every tool result
    eager_bind: bool = True  # bind the character when the server starts (off for `tools`)


class Game:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self._rcon = RconClient(cfg.host, cfg.port, cfg.password, cfg.rcon_timeout_s)
        self._bridge = Bridge(self._rcon, cfg.character)
        self._bound: dict[str, Any] | None = None
        self._lock = asyncio.Lock()
        self._queue: str | None = None
        self._notice: str | None = None
        self._bridge.rebind = self._rebind

    # The job queue: every job this character is given joins one chain, so a
    # failure cancels everything queued behind it (the mod does the
    # cancelling). Once the agent has been told about the failure, the next
    # job starts a new chain. The chain id lives in a small state file so
    # separate `factorio-mcp call` processes for one character share it.
    def _queue_file(self) -> Path:
        base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
        return Path(base) / "factorio-mcp" / "queues.json"

    def _queue_key(self) -> str:
        return f"{self.cfg.host}:{self.cfg.port}/{self.cfg.character}"

    def _read_queue_state(self) -> dict[str, Any]:
        """The shared state entry: {"chain": id, "last_tick": n}. The old
        format was a bare chain string — migrate it with last_tick 0."""
        try:
            v = json.loads(self._queue_file().read_text()).get(self._queue_key())
        except (OSError, ValueError, AttributeError):
            v = None
        if isinstance(v, dict):
            return v
        if isinstance(v, str):
            return {"chain": v, "last_tick": 0}
        return {}

    def _write_queue_state(self, state: dict[str, Any]) -> None:
        path = self._queue_file()
        try:
            try:
                data = json.loads(path.read_text())
                if not isinstance(data, dict):
                    data = {}
            except (OSError, ValueError):
                data = {}
            data[self._queue_key()] = state
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_suffix(f".{os.getpid()}.tmp")
            tmp.write_text(json.dumps(data))
            os.replace(tmp, path)
        except OSError:
            pass  # in-memory only

    @property
    def queue(self) -> str:
        if self._queue is None:
            self._queue = self._read_queue_state().get("chain")
            if not self._queue:
                self.new_queue()
        assert self._queue is not None
        return self._queue

    def new_queue(self, baseline_tick: int | None = None) -> None:
        """Starts a fresh chain for this character. baseline_tick re-anchors
        the restart detector's timeline (used when a rollback was detected:
        the server's tick legitimately went backward)."""
        state = self._read_queue_state()
        self._queue = f"{self.cfg.character}:{uuid.uuid4().hex[:12]}"
        state["chain"] = self._queue
        if baseline_tick is not None:
            state["last_tick"] = baseline_tick
        self._write_queue_state(state)

    def _note_tick(self, tick: int) -> None:
        """Remembers the highest server tick this character has seen, so a
        later bind can detect a rollback (a restart onto an older autosave)."""
        state = self._read_queue_state()
        if tick > int(state.get("last_tick") or 0):
            state["last_tick"] = tick
            self._write_queue_state(state)

    async def _check_restart(self, tick: int) -> None:
        """After binding: a server tick BELOW the last one this character saw
        means the game rolled back to an older save. Every job queued since
        that save is gone server-side, so the chain is dead although it never
        "failed" — no failure event will ever acknowledge it (the wedge that
        stalled coal's lane through the 0.2.16 deploy). Cancel whatever the
        rolled-back save resurrected in the lane, start a fresh chain, and
        tell the agent on the next tool result."""
        state = self._read_queue_state()
        last = int(state.get("last_tick") or 0)
        if tick <= 0:
            return
        if last and tick < last:
            try:
                await self._bridge.call("cancel", {"all": True})
                cancelled = True
            except ModError:
                cancelled = False
            self.new_queue(tick)
            self._notice = (
                f"[factorio-mcp] the server restarted and rolled back (tick {last} -> {tick}): the jobs queued in "
                f"your old chain are gone{' and the stale lane was cancelled' if cancelled else ''}. A fresh queue "
                f"was started — resubmit what still matters."
            )
            log.info("restart rollback detected for %s (tick %d -> %d); fresh queue started",
                     self.cfg.character, last, tick)
        else:
            self._note_tick(tick)

    def take_notice(self) -> str:
        """One-shot: the restart notice for the next tool result, if any."""
        notice, self._notice = self._notice, None
        return notice or ""

    @property
    def character(self) -> str:
        return self.cfg.character

    @property
    def bound_info(self) -> dict[str, Any] | None:
        return self._bound

    async def bridge(self) -> Bridge:
        """The bound bridge; connects and binds on first use (and after a lost binding)."""
        if self._bound is not None:
            return self._bridge
        async with self._lock:
            if self._bound is None:
                try:
                    self._bound = await self._bridge.connect_and_bind(takeover=self.cfg.takeover)
                except ModError as e:
                    raise ModError(
                        f"cannot use the game at {self.cfg.host}:{self.cfg.port} as character "
                        f"'{self.cfg.character}': {e}"
                    ) from e
                body = self._bound["body"]
                await self._check_restart(int(self._bound["ping"].get("tick") or 0))
                log.info(
                    "bound character %s at (%.1f, %.1f)%s",
                    self.cfg.character,
                    body["position"]["x"],
                    body["position"]["y"],
                    " (took over)" if body.get("took_over") else "",
                )
        return self._bridge

    def lost_binding(self) -> None:
        self._bound = None

    async def _rebind(self) -> None:
        """The mod no longer knows this session (someone else took the character,
        or our lease lapsed): bind again. Fails loudly when another live session
        holds the character and takeover isn't configured."""
        log.info("binding for %s was lost; binding again", self.cfg.character)
        self.lost_binding()
        await self.bridge()

    async def call(self, method: str, params: dict[str, Any] | None = None) -> Any:
        b = await self.bridge()
        try:
            return await b.call(method, params)
        except ModError as e:
            if "does not hold character" in str(e):
                # Someone took the character over; next call re-binds (and
                # fails loudly unless takeover is configured).
                self.lost_binding()
            raise

    async def heartbeat_loop(self) -> None:
        while True:
            await asyncio.sleep(HEARTBEAT_S)
            if self._bound is None:
                continue
            try:
                reply = await self._bridge.call("heartbeat")
                self._note_tick(int(reply.get("tick") or 0))
            except ModError as e:
                print(f"[factorio-mcp] heartbeat failed: {e}", file=sys.stderr)
                if "does not hold character" in str(e):
                    self.lost_binding()

    async def close(self) -> None:
        if self._bound is not None:
            try:
                await self._bridge.call("unbind")
            except Exception:
                pass
        self._rcon.close()
