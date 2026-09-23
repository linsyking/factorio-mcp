# factorio-mcp

An MCP server that gives **one AI agent control of one Factorio character**, using only normal player mechanics. Run as many instances as you have agents: each one binds its own character on the same server, and they all act in parallel.

- **Policy-free.** Tools describe what they do, never why or when to use them. Planning, delegation, subagents and coordination all live on the agent side.
- **1 agent ↔ 1 MCP instance (stdio) ↔ 1 character.** The character is bound at startup, so tools take no character argument. A binding guard stops two instances from driving the same character.
- **Fair play.**
  - normal walking speed along the game pathfinder;
  - vanilla hand-mining and crafting time;
  - reach and build-range checks;
  - items only ever come from and go to the character's own inventory;
  - new characters get the freeplay start kit and nothing else.
- **Fog of war.** Agents perceive only explored ground and see enemies only while visible. This matters because the engine never charts the map for characters without a player.
- **Jobs.** Walking, mining, crafting and building run as jobs on the character. Tools wait up to `wait_s`, then return a job id for `job_wait`, `job_status` or `job_cancel`.

**Production math** is a separate MCP server in [`calc/`](calc/) (`factorio-calc-mcp`, AGPL-3.0, wrapping FactorioCalc). It gives ratios, machine counts, mining drills and belts, and needs no game connection. Agents plan with it and act with this one.

Game side: a Lua mod forked from [Agentic-Factorio](https://github.com/matteomekhail/Agentic-Factorio) (MIT); see [UPSTREAM.md](UPSTREAM.md). MCP side: Python with the official MCP SDK 2.x. Targets Factorio **2.0.77**, with or without Space Age.

## Install

### 1. The mod on the game server

The server must be multiplayer-hosted or headless with RCON enabled, and **`auto_pause` must be `false`**; otherwise nothing moves while no human is online. For the `factoriotools/factorio` Docker image over SSH:

```bash
scripts/deploy_mod.sh cc@your-host /path/to/compose-dir factorio   # package, copy, enable, restart
```

Otherwise run `uv run factorio-mcp package-mod`, copy `dist/factorio-mcp_<version>.zip` into the server's `mods/` folder, enable it in `mod-list.json`, and restart.

Humans who join the server need the same mod version installed, because it isn't on the mod portal.

**Mod settings** (runtime, map settings):

| Setting | Default | Meaning |
|---|---|---|
| max characters | 32 | Maximum number of agent characters at once |
| chart radius | 2 chunks | Explored area around each agent character |
| view radius | 32 tiles | How close enemies must be to be seen |
| explore radius | 64 tiles | How far into unexplored land a walk goal may be |

### 2. The MCP server for each agent

```bash
cd factorio-mcp && uv sync
uv run factorio-mcp doctor      # RCON + mod check (needs the env vars below)
uv run factorio-mcp tools       # list the tools and the server instructions
```

| Variable | Default | |
|---|---|---|
| `FACTORIO_RCON_HOST` / `FACTORIO_RCON_PORT` | `127.0.0.1` / `27015` | |
| `FACTORIO_RCON_PASSWORD` | — | required |
| `FACTORIO_CHARACTER` | `agent` | the character this instance controls, e.g. `scout-1` |
| `FACTORIO_TAKEOVER` | `0` | `1` = take the character over even if another session holds it |
| `FACTORIO_MCP_WAIT_S` | `30` | default `wait_s` for job tools |

Claude Code (`.mcp.json` in the project), one entry per agent:

```json
{
  "mcpServers": {
    "factorio-scout": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/factorio-mcp", "factorio-mcp", "serve"],
      "env": { "FACTORIO_RCON_HOST": "your-host", "FACTORIO_RCON_PASSWORD": "…", "FACTORIO_CHARACTER": "scout-1" }
    }
  }
}
```

Without a native MCP client, `factorio-mcp call TOOL '{json}' TOOL2 …` runs tool calls through a real MCP client session.

## Tools (44)

| Group | Tools |
|---|---|
| Session | `status` |
| Perception | `look_around`, `check_inventory`, `inspect_entity` (up to 16 at once), `scan_area` (ASCII grid, `?` = unexplored), `describe_prototype`, `analyze_factory`, `can_place` (up to 24 at once), `find_buildable_area`, `production_stats` (items and fluids, 5s–1000h windows), `list_trains` |
| Blueprints | `list_blueprints`, `read_blueprint`, `import_blueprint`, `export_blueprint` (explored area → string), `build_blueprint` (string or carried, up to 1000 entities) |
| Chat and events | `read_chat`, `get_events`, `wait_for_events` (long-poll), `say` |
| Instant actions | `start_research`, `equip`, `exit_vehicle`, `set_train_schedule`, `respawn` |
| Jobs | `walk_to`, `drive_to`, `follow_player`, `mine`, `place_entity`, `craft_items`, `insert_items`, `extract_items`, `set_recipe`, `rotate_entity`, `build_plan` (up to 100 steps, `dry_run`), `run_plan` (chained steps), `deconstruct`, `fight`, `defend_area`, `keep_fueled` |
| Job control | `job_status`, `job_wait`, `job_cancel` |

Other conventions:
- Items of non-normal quality are written `name@quality`.
- Directions are 16-way: 0 = N, 4 = E, 8 = S, 12 = W.
- The wire protocol is in [docs/PROTOCOL.md](docs/PROTOCOL.md).
- A comparison with the other Factorio MCPs is in [research/factorio-agent/11-comparison.md](../research/factorio-agent/11-comparison.md).

## Tests

```bash
for t in tests/mod/*.lua; do lua $t; done        # mod unit tests (stubbed game API)
uv run pytest                                     # RCON/bridge tests against a fake RCON server
FACTORIO_LIVE=1 FACTORIO_RCON_HOST=… FACTORIO_RCON_PASSWORD=… uv run pytest tests/live -s
```

**The live test** runs 3 agents as 3 MCP processes at once. It checks:
- a second session for a taken character is refused;
- parallel walks at vanilla speed;
- jobs are private to their character;
- fog of war on scans, placement checks and walks;
- vanilla mining time, reflected in `production_stats`;
- it retires its characters afterwards.

## Known limitations

- **Not built in:** belt, pipe or pole routing tools; throughput/bottleneck analysis beyond `analyze_factory` and `production_stats`; module/beacon upgrade jobs; circuit and filter settings; space-platform tools.
- **Quality:** inventories, transfers and placement carry quality. Hand-crafting and production statistics are per item name.
- **Surfaces:** characters spawn on Nauvis; perception and actions use the character's current surface.
- **Pathfinder:** it knows terrain the agent hasn't seen. Goals are limited to explored ground plus 64 tiles.
