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
- **Jobs, queued ahead.** Walking, mining, crafting and building run as jobs on the character, in order.
  - A job tool queues its job and returns at once (`wait_s` 0 by default), so an agent can queue a whole phase as if every step succeeds and keep thinking while the character works.
  - All of a session's jobs form one chain. If one fails, the mod cancels everything queued behind it, and the next tool result reports it; the next job starts a new chain. The chain id is kept in `~/.local/state/factorio-mcp/queues.json`, so separate `factorio-mcp call` processes for a character share it.
  - `job_wait`, `job_status` and `job_cancel` are there when the agent needs them.
- **Build checks.**
  - The `build_plan` dry run and its real result report belt-flow problems: a corner that dead-ends next to the belt it should turn into, and belts facing each other. They also say what every inserter picks from and drops into, and warn when one faces the wrong way.
  - A mining drill outputs onto exactly one tile — the middle tile of its facing side, next to the footprint; a belt beside the drill collects nothing. Checks warn when neither the plan nor the ground puts a receiver (belt/chest/machine) on that tile, for drills the plan places and for existing drills near it.
  - Inserters can be placed with `drop_to` / `pickup_from` instead of a direction — preferred, because an inserter's direction integer is the side it PICKS UP FROM (facing north it picks from the north tile and drops south), the opposite of the pointing-at-the-drop-target reading. The scan footer lists each inserter's direction with its two ends, so a placement can be verified at a glance.
  - `scan_area` draws your belts as `^ > v <` and lists your inserters' ends, and every mining drill's output tile with what stands there (drills with an empty output or no minable resources first).
- **Batches that stop.**
  - A multi-tool `factorio-mcp call` stops at the first failure.
  - `run_plan` lists every step's outcome.
  - Steps and inserts marked `optional` report their failure without cancelling the jobs behind them.
- **Every tool result ends with news:** jobs finished or failed since the previous call, other events, and unread game chat from players and other agents. Agents never need to poll.

**Production math** is a separate MCP server in [`calc/`](calc/) (`factorio-calc-mcp`, AGPL-3.0, wrapping FactorioCalc). It gives ratios, machine counts, mining drills and belts, and needs no game connection. Agents plan with it and act with this one.

Game side: a Lua mod forked from [Agentic-Factorio](https://github.com/matteomekhail/Agentic-Factorio) (MIT); see [UPSTREAM.md](UPSTREAM.md). MCP side: Python with the official MCP SDK 2.x. Targets Factorio **2.0.77**, with or without Space Age.

## Install

### 1. The mod on the game server

The server must be multiplayer-hosted or headless with RCON enabled, and **`auto_pause` must be `false`**; otherwise nothing moves while no human is online. For the `factoriotools/factorio` Docker image over SSH:

```bash
scripts/deploy_mod.sh cc@your-host /path/to/compose-dir factorio   # package, copy, enable, restart
# also publish the zip + download page, and keep a checkout on the server in step
# (refuses uncommitted changes; pushes, deploys, then git pull there):
PUBLISH_DIR=/srv/site/factorio PUBLISH_SERVER_ADDRESS=your-host:34197 \
SERVER_REPO=/path/to/factorio-mcp scripts/deploy_mod.sh cc@your-host /path/to/compose-dir factorio
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
| `FACTORIO_CHARACTER` | `agent` | the character this instance controls, e.g. `scout-1` (`factorio-mcp tools` never binds one) |
| `FACTORIO_TAKEOVER` | `0` | `1` = take the character over even if another session holds it |
| `FACTORIO_MCP_WAIT_S` | `0` | default `wait_s` for job tools; 0 = queue and return at once |
| `FACTORIO_MCP_INBOX` | `1` | append unread game chat (players, other agents) to every tool result, so agents never need to poll `read_chat`; `0` turns it off |

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

## Tools (54)

| Group | Tools |
|---|---|
| Session | `status` |
| Perception | `map_overview` (the map screen: patches, rocks, water, enemy bases on all known ground, up to 640 tiles), `look_around` (up to 150 tiles), `check_inventory`, `inspect_entity` (up to 16 at once), `scan_area` (ASCII grid, `?` = unexplored, radius up to 120, downsampled above 40), `describe_prototype`, `analyze_factory`, `map_warnings` (every warning on charted ground, grouped by problem with positions), `alerts` (the game's alert panel: under attack, turret out of ammo, destroyed, ...), `battle_report` (damaged entities, turrets with no ammo, enemy clusters with distances, recent combat), `can_place` (up to 24 at once), `find_buildable_area`, `production_stats` (items and fluids, 5s–1000h windows), `list_trains` |
| Blueprints | `list_blueprints`, `read_blueprint`, `import_blueprint`, `export_blueprint` (explored area → string), `build_blueprint` (string or carried, up to 1000 entities) |
| Chat and events | `read_chat`, `get_events`, `wait_for_events` (long-poll), `say`, `set_status` (a line for people watching) |
| Instant actions | `start_research`, `equip`, `exit_vehicle`, `set_train_schedule`, `respawn` |
| Jobs | `walk_to`, `drive_to`, `follow_player`, `mine`, `place_entity`, `craft_items`, `insert_items`, `extract_items`, `set_recipe`, `rotate_entity`, `build_plan` (up to 100 steps, `dry_run`), `run_plan` (chained steps, including `wait_until`), `wait_until` (seconds, an item count in an entity or your inventory, or a research), `deconstruct`, `fight`, `defend_area`, `keep_fueled` |
| Routing and belt checks | `route_belt`, `route_pipe` (plan on explored ground; `build=true` queues normal build jobs), `trace_belt` (a line's legs, ends, feeders and takers, and each lane's contents and fill %), `measure_belt` (items/min passing a tile, per lane, against capacity; flowing, backed up or empty) |
| Job control | `job_status`, `job_wait`, `job_cancel` |

Other conventions:
- Items of non-normal quality are written `name@quality`.
- Directions are 16-way: 0 = N, 4 = E, 8 = S, 12 = W.
- The wire protocol is in [docs/PROTOCOL.md](docs/PROTOCOL.md).
- A comparison with the other Factorio MCPs is in [research/factorio-agent/11-comparison.md](../research/factorio-agent/11-comparison.md).

## Routing

`route_belt` and `route_pipe` plan a path between two endpoints and return it as build steps, an item bill and its side effects. With `build=true` they queue ordinary jobs: mine the obstacles in the way, then a `build_plan` of normal placements from the character's inventory.

**Endpoints.** An endpoint is a tile, or a port of an existing entity: an inserter's `drop` or `pickup` tile, a drill's drop tile, a `belt` to join, or a `fluid` connection. A route that ends on a belt says whether it extends that belt, side-loads it, or turns it into a curve.

**Search.** Weighted A* (weight 1.2) over (tile, direction) states:
- Belts move straight, turn left or turn right.
- Underground pairs jump 2 to `max_underground_distance` tiles. That is 5 for yellow belts and 10 for pipe-to-ground, read from the prototypes.
- Costs: a step is 1, a turn +0.5, and an underground pair its span plus 4, so it is used only when it saves something. A tree or rock costs 3 (only with `clear_obstacles`), and a tile next to a foreign belt +0.2.

**The grid.** It is built lazily from the game:
- A tile is legal when a forced blueprint-ghost check of the belt or pipe fits there and no cliff overlaps it. Unexplored chunks are walls.
- The router records the tiles other belts feed into, inserter pickup and drop tiles, drill drop tiles, and foreign pipe connections. Routes never feed into or side-load a foreign belt by accident, and never merge fluids.
- `avoid` rectangles and `planned_belts` (belts you intend to build) are respected.

**Checks.**
- A validator replays the finished belt line and rejects accidental side-loads and mis-paired undergrounds. The offending states are banned and the search retried.
- Undergrounds are used only if the character carries them or their recipe is unlocked; otherwise the route goes around.
- Limits: the search box is at most 160 tiles a side, and a search stops after 200 000 expansions.

**Credits.**
- The forced-ghost legality check and the soft treatment of trees and rocks follow [FactorioMayor](https://github.com/khoyga007/FactorioMayor)'s route planner (`field.lua`).
- The (tile, direction) state space and the underground-edge model follow [Factorio-SAT](https://github.com/R-O-C-K-E-T/Factorio-SAT)'s belt-routing encoding (GPL-3.0).

This is a personal research project and is not distributed. The router's Lua is our own code, written from those designs; where the designs are GPL-3.0, treat `mod/factorio-mcp/scripts/route/` as GPL-3.0-or-later.

## Watching agents in game

Any player can type these in chat. They're a viewing aid for people; agents never see them.

| Command | Effect |
|---|---|
| `/follow [name]` | Remote view that stays centred on the agent. It re-centres after the agent respawns or when you pan away; Esc stops it. With one agent the name is optional. |
| `/follow-cam [name]` | A camera window that follows the agent while you keep playing. |
| `/follow-cams` | One camera window per agent and per other connected player, laid out side by side. Windows come and go with the characters; run it again to close all of them. |
| `/unfollow` | Stop all of these. |

**Windows.**
- `/follow-cams` windows are tiled to fit your screen: 3 per row at 1920×1080 (600×375 cameras), 4 on a 2560-wide screen.
- When more windows come than fit, all of them shrink together (7 → 4×2 at 446×278 on 1080p), so none opens off-screen. Below the minimum size (240×150), extras stack with an offset on screen.
- Tiling runs when a window opens or closes, on the `#` button, and when the resolution or UI scale changes.
- Other title-bar buttons: `-` / `+` for size (×1.25 steps), `z-` / `z+` for zoom, and `x` to close. Drag a window by its title bar; drags and resizes last until the next tiling.
- Factorio doesn't let mods resize windows by dragging their edges.

**Status lines.** Every agent window shows a status line under its camera (nothing is drawn above the character):
- the agent's own text, set with the `set_status` tool;
- what its running job is doing, e.g. `building the coal outpost — mining coal 12/60 (+2 queued)`.

## Tests

```bash
for t in tests/mod/*.lua; do lua $t; done        # mod unit tests (stubbed game API)
uv run --with lupa python scripts/run_mod_tests.py   # the same, without a system lua binary
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

- **Not built in:** power-pole routing; multi-lane, splitter or balancer synthesis (the router makes one belt or pipe line at a time); throughput/bottleneck analysis beyond `analyze_factory` and `production_stats`; module/beacon upgrade jobs; circuit and filter settings; space-platform tools.
- **Quality:** inventories, transfers and placement carry quality. Hand-crafting and production statistics are per item name.
- **Surfaces:** characters spawn on Nauvis; perception and actions use the character's current surface.
- **Pathfinder:** it knows terrain the agent hasn't seen. Goals are limited to explored ground plus 64 tiles.
