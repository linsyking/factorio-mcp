"""Live tests against a real Factorio server running the factorio-mcp mod.

Opt-in: FACTORIO_LIVE=1 plus FACTORIO_RCON_HOST / FACTORIO_RCON_PORT /
FACTORIO_RCON_PASSWORD. Each agent is a separate MCP server process driven
through a real MCP client session over stdio — exactly how agents use it.

  FACTORIO_LIVE=1 FACTORIO_RCON_HOST=... FACTORIO_RCON_PASSWORD=... uv run pytest tests/live -s
"""

from __future__ import annotations

import asyncio
import os
import re
import sys
import time
from contextlib import AsyncExitStack

import pytest
from mcp.client.session import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client

pytestmark = pytest.mark.skipif(os.environ.get("FACTORIO_LIVE") != "1", reason="set FACTORIO_LIVE=1 to run live tests")

WALK_TILES_PER_S = 0.15 * 60  # vanilla running speed without bonuses
RUN_ID = str(int(time.time()) % 100000)


class Agent:
    def __init__(self, name: str, takeover: bool = False):
        self.name, self.takeover = name, takeover
        self.stack = AsyncExitStack()
        self.session: ClientSession | None = None

    async def __aenter__(self):
        env = dict(os.environ, FACTORIO_CHARACTER=self.name, FACTORIO_TAKEOVER="1" if self.takeover else "0")
        params = StdioServerParameters(command=sys.executable, args=["-m", "factorio_mcp", "serve"], env=env)
        read, write = await self.stack.enter_async_context(stdio_client(params))
        self.session = await self.stack.enter_async_context(ClientSession(read, write))
        await self.session.initialize()
        return self

    async def __aexit__(self, *exc):
        await self.stack.aclose()

    async def call(self, tool: str, args: dict | None = None) -> tuple[bool, str]:
        r = await self.session.call_tool(tool, args or {})
        return (not r.is_error), "\n".join(getattr(c, "text", "") for c in r.content)

    async def ok(self, tool: str, args: dict | None = None) -> str:
        ok, text = await self.call(tool, args)
        assert ok, f"{self.name} {tool} failed: {text}"
        return text

    async def position(self) -> tuple[float, float]:
        text = await self.ok("look_around", {"radius": 10})
        m = re.search(r"at \((-?[\d.]+), (-?[\d.]+)\)", text)
        return float(m.group(1)), float(m.group(2))


async def test_parallel_agents_fairness_and_isolation():
    names = [f"live-{RUN_ID}-{i}" for i in range(3)]
    async with Agent(names[0]) as a, Agent(names[1]) as b, Agent(names[2]) as c:
        agents = [a, b, c]
        for ag in agents:
            print(await ag.ok("status"))

        # 1. binding guard: a second live session for the same character is refused
        async with Agent(names[0]) as dup:
            ok, text = await dup.call("status")
            assert not ok and "bound to another live MCP session" in text, text
            print("double bind refused:", text.splitlines()[0][:160])

        # 2. three characters walk at the same time in different directions
        starts = [await ag.position() for ag in agents]
        targets = [(starts[0][0] + 30, starts[0][1]), (starts[1][0] - 30, starts[1][1]), (starts[2][0], starts[2][1] + 30)]
        t0 = time.monotonic()
        results = await asyncio.gather(*(ag.ok("walk_to", {"x": x, "y": y, "wait_s": 60}) for ag, (x, y) in zip(agents, targets)))
        wall = time.monotonic() - t0
        ends = [await ag.position() for ag in agents]
        for r, (ex, ey), (tx, ty) in zip(results, ends, targets):
            assert "done" in r, r
            assert abs(ex - tx) <= 1.5 and abs(ey - ty) <= 1.5, (ex, ey, tx, ty)
        min_time = 30 / WALK_TILES_PER_S
        print(f"3 parallel 30-tile walks finished in {wall:.1f}s wall (vanilla minimum {min_time:.1f}s each)")
        assert wall >= min_time * 0.9, "walked faster than vanilla running speed"
        assert wall < min_time * 3 + 10, "walks did not run in parallel"

        # 3. jobs are private: b can't read or cancel a's job
        jr = await a.ok("walk_to", {"x": ends[0][0] - 5, "y": ends[0][1], "wait_s": 0})
        job_id = int(re.search(r"#(\d+)", jr).group(1))
        ok, text = await b.call("job_status", {"job_id": job_id})
        assert not ok and "doesn't belong" in text, text
        ok, text = await b.call("job_cancel", {"job_id": job_id})
        assert not ok and "doesn't belong" in text, text
        print(await a.ok("job_wait", {"job_id": job_id, "timeout_s": 30}))

        # 4. fog of war: far away is unexplored
        scan = await a.ok("scan_area", {"x": ends[0][0] + 400, "y": ends[0][1], "radius": 10})
        grid = scan.split("```")[1]
        assert set(grid.replace("\n", "")) <= {"?"}, grid[:200]
        ok, text = await a.call("can_place", {"item": "stone-furnace", "x": ends[0][0] + 400, "y": ends[0][1]})
        assert not ok and "unexplored" in text, text
        ok, text = await a.call("walk_to", {"x": ends[0][0] + 400, "y": ends[0][1], "wait_s": 5})
        assert not ok and "unexplored" in text, text
        print("fog of war enforced:", text[:140])

        # 5. hand mining takes vanilla time and shows up in production stats
        st = await a.ok("look_around", {"radius": 80})
        print(st)
        m = re.search(r"(coal|stone|iron-ore|copper-ore) [\d,]+ in \d+ tiles, center \((-?[\d.]+), (-?[\d.]+)\)", st)
        if m:
            res, rx, ry = m.group(1), float(m.group(2)), float(m.group(3))
            await a.ok("walk_to", {"x": rx, "y": ry, "wait_s": 90})
            t0 = time.monotonic()
            out = await a.ok("mine", {"resource": res, "count": 4, "wait_s": 90})
            dt = time.monotonic() - t0
            print(out, f"({dt:.1f}s wall for 4 ops)")
            assert dt >= 4 * 1.9, f"mined faster than vanilla: {dt:.1f}s"
            stats = await a.ok("production_stats", {"window": "1m", "names": [res]})
            print(stats)
            assert re.search(rf"{res} \(item\): \+[1-9]", stats), stats
        else:
            print("no resource patch on explored ground near", names[0], "— skipped the mining check")

        for ag in agents:
            await ag.ok("job_cancel", {"all": True})
    # clean up the test characters
    for n in names:
        proc = await asyncio.create_subprocess_exec(
            sys.executable, "-m", "factorio_mcp", "retire", "--character", n,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await proc.communicate()
        print(out.decode().strip())
