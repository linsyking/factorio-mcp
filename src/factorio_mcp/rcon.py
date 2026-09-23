"""Asyncio Source-RCON client for Factorio.

One command -> one reply packet with the command's id. Factorio 2.0.77 sends
a whole reply in one packet (measured up to 1 MB; the mod also chunks its
envelopes at 3.4 kB), and replies may arrive out of order: while a player is
connected, a Lua command that changes game state can be answered after a
command sent right behind it. So this client does not use Agentic-Factorio's
"sentinel" trick (send a no-op after each command and treat its reply as the
end marker) — that silently returned empty replies with a player online. It
waits for the reply whose id matches, and never pipelines.
"""

from __future__ import annotations

import asyncio
import struct

AUTH = 3
EXEC_COMMAND = 2
AUTH_RESPONSE = 2
MAX_PACKET = 8 * 1024 * 1024


class RconError(Exception):
    pass


def encode_packet(req_id: int, kind: int, body: str) -> bytes:
    payload = struct.pack("<ii", req_id, kind) + body.encode("utf-8") + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


class RconClient:
    def __init__(self, host: str, port: int, password: str, timeout_s: float = 15.0):
        self.host, self.port, self.password, self.timeout_s = host, port, password, timeout_s
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None
        self._lock = asyncio.Lock()
        self._next_id = 1

    @property
    def connected(self) -> bool:
        return self._writer is not None and not self._writer.is_closing()

    def _alloc(self) -> int:
        i = self._next_id
        self._next_id = 1 if i >= 0x7FFFFFFE else i + 1
        return i

    async def _read_packet(self) -> tuple[int, int, bytes]:
        assert self._reader is not None
        head = await self._reader.readexactly(4)
        (size,) = struct.unpack("<i", head)
        if size < 10 or size > MAX_PACKET:
            raise RconError(f"malformed RCON packet (size={size})")
        data = await self._reader.readexactly(size)
        req_id, kind = struct.unpack("<ii", data[:8])
        return req_id, kind, data[8:-2]

    async def connect(self) -> None:
        if self.connected:
            return
        self.close()
        try:
            self._reader, self._writer = await asyncio.wait_for(
                asyncio.open_connection(self.host, self.port), self.timeout_s
            )
        except (OSError, asyncio.TimeoutError) as e:
            self.close()
            raise RconError(f"cannot connect to RCON at {self.host}:{self.port}: {e}") from e
        auth_id = self._alloc()
        self._writer.write(encode_packet(auth_id, AUTH, self.password))
        await self._writer.drain()
        try:
            while True:
                req_id, kind, _ = await asyncio.wait_for(self._read_packet(), self.timeout_s)
                if kind != AUTH_RESPONSE:
                    continue  # some servers send an empty RESPONSE_VALUE first
                if req_id == -1:
                    raise RconError("RCON auth failed — wrong password?")
                return
        except (asyncio.TimeoutError, asyncio.IncompleteReadError, OSError) as e:
            self.close()
            raise RconError(f"RCON auth failed: {e!r}") from e
        except RconError:
            self.close()
            raise

    async def exec(self, command: str) -> str:
        """Runs one console command and returns its full response text.
        Commands on one connection are serialized."""
        async with self._lock:
            if not self.connected:
                await self.connect()
            assert self._writer is not None
            cmd_id = self._alloc()
            self._writer.write(encode_packet(cmd_id, EXEC_COMMAND, command))
            try:
                await self._writer.drain()

                async def reply() -> bytes:
                    while True:
                        req_id, _, body = await self._read_packet()
                        if req_id == cmd_id:
                            return body

                body = await asyncio.wait_for(reply(), self.timeout_s)
            except (asyncio.TimeoutError, asyncio.IncompleteReadError, OSError) as e:
                # The stream position is unknown now — drop the connection.
                self.close()
                raise RconError(f"RCON command failed: {e!r}") from e
            return body.decode("utf-8", errors="replace")

    def close(self) -> None:
        if self._writer is not None:
            try:
                self._writer.close()
            except Exception:
                pass
        self._reader = self._writer = None
