"""The MCP server (stdio): one instance = one agent = one Factorio character."""

from __future__ import annotations

import asyncio
import logging
import sys
from contextlib import asynccontextmanager

from mcp.server.mcpserver import MCPServer

from . import tools
from .bridge import ModError
from .game import Config, Game

INSTRUCTIONS = """\
You control ONE Factorio character, named "{character}". Every tool acts as that character.

Model of the world:
- Coordinates are map tiles: x grows east, y grows south. Directions are 16-way: 0=north, 4=east, 8=south, 12=west.
- Item names are internal names ("iron-plate"); other qualities are written "name@quality" ("iron-plate@rare").
- Multi-tick actions (walking, mining, crafting, placing, building, fighting, duties) run as jobs on your character, one
  after another in order. Job tools wait up to wait_s seconds (default {wait:g}) and otherwise return a job id; use
  job_status, job_wait and job_cancel. Other agents' characters act in parallel with their own jobs.
- Your character follows normal player mechanics: walking speed, hand-mining and crafting time, reach and build range,
  items come from and go to its own inventory, placement rules. Nothing is created from nothing.
- Fog of war: you only perceive explored ground (chunks your character or your force has seen). Unexplored tiles
  show as '?' in scan_area. Enemies are only reported while visible. Walk goals must be explored or within the
  exploration radius of your character.
- get_events / wait_for_events report your jobs finishing or failing, attacks on your character, research finished.
"""


def build_app(cfg: Config) -> MCPServer:
    game = Game(cfg)

    @asynccontextmanager
    async def lifespan(_app: MCPServer):
        async def eager_bind():
            try:
                await game.bridge()
            except ModError as e:
                print(f"[factorio-mcp] not connected yet: {e}", file=sys.stderr)

        bind_task = asyncio.create_task(eager_bind())
        hb = asyncio.create_task(game.heartbeat_loop())
        try:
            yield game
        finally:
            hb.cancel()
            bind_task.cancel()
            await game.close()

    app = MCPServer(
        name="factorio-mcp",
        version="0.1.0",
        instructions=INSTRUCTIONS.format(character=cfg.character, wait=cfg.default_wait_s),
        lifespan=lifespan,
    )
    tools.register(app, game)
    return app


def run(cfg: Config) -> None:
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="[factorio-mcp] %(message)s")
    build_app(cfg).run()
