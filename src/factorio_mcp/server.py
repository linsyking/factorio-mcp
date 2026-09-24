"""The MCP server (stdio): one instance = one agent = one Factorio character."""

from __future__ import annotations

import asyncio
import logging
import sys
from contextlib import asynccontextmanager

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError

from . import tools
from .bridge import ModError
from .game import Config, Game
from .tools import TOOL_MIN_MOD, fmt_version, gated_tools

INSTRUCTIONS = """\
You control ONE Factorio character, named "{character}". Every tool acts as that character.

Model of the world:
- Coordinates are map tiles: x grows east, y grows SOUTH. So north is smaller y: (5, -29) is north of (5, -28), and a
  belt facing south (8) at y = -28 feeds y = -27. Directions are 16-way: 0=north, 4=east, 8=south, 12=west; most
  buildings face only those four.
- After building belts, check them: trace_belt shows where a line goes, how it ends (a dead end backs everything up),
  what feeds it and what's on each lane; measure_belt counts real throughput per lane against the belt's capacity.
- Item names are internal names ("iron-plate"); other qualities are written "name@quality" ("iron-plate@rare").
- Multi-tick actions (walking, mining, crafting, placing, building, fighting, duties) run as jobs on your character, one
  after another in order. A job tool queues its job behind your earlier ones and waits up to wait_s seconds (default
  {wait:g}) before returning the job id, so you can queue many steps ahead without waiting. If a job fails, every job
  queued after it is cancelled and you are told on your next call; queue again from there. job_status, job_wait and
  job_cancel manage jobs. Other agents' characters act in parallel with their own jobs.
- Query tools (look_around, check_inventory, inspect_entity, ...) show the game now, not after your queued jobs
  have run; use wait_until / job_wait to look after them.
- Every tool result ends with what happened since your previous call: your jobs that finished or failed, and events.
  It also lists game chat you haven't seen yet ("New chat:"), from players and other agents. Each line is shown once;
  read_chat and get_events re-read older lines with since_id.
- When your force's warning counts change anywhere (machines losing power or fuel, dead drills, outputs backing up...),
  your next tool result carries an ALERTS line, e.g. "ALERTS: no-power 38 (+38 since your last call)" — steady state
  prints nothing. waiting-for-space back-pressure never triggers the line; it only rides as a trailing summary count.
  map_warnings gives the full punch list with positions.
- Your character follows normal player mechanics: walking speed, hand-mining and crafting time, reach and build range,
  items come from and go to its own inventory, placement rules. Nothing is created from nothing.
- Fog of war: you only perceive explored ground (chunks your character or your force has seen). Unexplored tiles
  show as '?' in scan_area. Enemies are only reported while visible. Walk goals must be explored or within the
  exploration radius of your character.
- get_events / wait_for_events report your jobs finishing or failing, attacks on your character, research finished.
"""


class StrictMCPServer(MCPServer):
    """Rejects unknown tool arguments. The SDK drops them silently, so a call
    like scan_area {"center": {...}} ran centred on the character.
    Also gates tools on the live server's mod version: never advertise or run
    a tool the mod will reject (the pick_up skew class)."""

    def __init__(self, *args, game: Game | None = None, **kwargs):
        super().__init__(*args, **kwargs)
        self._game = game

    async def list_tools(self):
        listed = await super().list_tools()
        game = self._game
        if game is None or not listed:
            return listed
        if game.mod_version is None:
            await game.probe_mod_version()  # one characterless ping; throttled
        hidden = gated_tools([t.name for t in listed], game.mod_version)
        if hidden:
            print(f"[factorio-mcp] not advertising {', '.join(hidden)} (needs a newer mod than the live "
                  f"{fmt_version(game.mod_version)})", file=sys.stderr)
            return [t for t in listed if t.name not in set(hidden)]
        return listed

    async def call_tool(self, name, arguments, context=None):
        need = TOOL_MIN_MOD.get(name)
        if need and self._game is not None:
            v = self._game.mod_version
            if v is None:
                v = await self._game.probe_mod_version()
            if v is not None and need > v:
                raise ToolError(
                    f"{name} needs mod {fmt_version(need)}+; the live game server runs factorio-mcp "
                    f"{fmt_version(v)} (deployed before this tool existed). Ask the coordinator to update the "
                    f"server mod — until then use another way to do this."
                )
        tool = self._tool_manager.get_tool(name)
        if tool is not None and arguments:
            known = set((tool.parameters or {}).get("properties", {}))
            unknown = sorted(set(arguments) - known)
            if unknown:
                raise ToolError(
                    f"{name}: unknown argument(s) {', '.join(unknown)}. "
                    f"Valid arguments: {', '.join(sorted(known)) or 'none'}."
                )
        return await super().call_tool(name, arguments, context)


def build_app(cfg: Config) -> MCPServer:
    game = Game(cfg)

    @asynccontextmanager
    async def lifespan(_app: MCPServer):
        async def eager_bind():
            try:
                await game.bridge()
            except ModError as e:
                print(f"[factorio-mcp] not connected yet: {e}", file=sys.stderr)

        bind_task = asyncio.create_task(eager_bind() if cfg.eager_bind else asyncio.sleep(0))
        hb = asyncio.create_task(game.heartbeat_loop())
        try:
            yield game
        finally:
            hb.cancel()
            bind_task.cancel()
            await game.close()

    app = StrictMCPServer(
        name="factorio-mcp",
        version="0.1.0",
        instructions=INSTRUCTIONS.format(character=cfg.character, wait=cfg.default_wait_s),
        lifespan=lifespan,
        game=game,
    )
    tools.register(app, game)
    return app


def run(cfg: Config) -> None:
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="[factorio-mcp] %(message)s")
    build_app(cfg).run()
