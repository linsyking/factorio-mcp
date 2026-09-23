# Protocol v6: MCP server ↔ game mod

`ping` returns `protocol_version: 5`. The MCP server refuses to bind when the versions differ.

## Transport

Every call is one RCON command:

```
/silent-command remote.call("factorio_mcp","rpc","<method>","<params as escaped JSON string>")
```

- **Params:** always a JSON **string**; the server escapes `\` and `"`.
- **Replies:** the mod answers on the same RCON response with `rcon.print(json)`.
- **One reply per command:** the client sends one command, then reads packets until the one carrying that command's id; that packet is the whole reply (Factorio 2.0.77 does not split replies — measured up to 1 MB). It never pipelines. Replies can come back out of order while a player is connected, so Agentic-Factorio's sentinel trick (a no-op sent right after each command, whose reply marks the end) is not used: with a player online it returned empty replies for state-changing calls such as `bind`.
- **Errors:** runtime Lua errors outside the mod's `pcall` come back as `Cannot execute command. Error: …` (the bridge reports it as an invalid envelope).

### Envelope

```jsonc
{ "ok": true, "data": { ... } }
{ "ok": false, "error": "human-readable message" }     // Lua file:line prefixes are stripped
```

**Chunking:** a reply over 3400 bytes is stored mod-side, and the first part comes back as `{ok, chunked: true, id, parts, data}`. The server then fetches parts 2..N with `get_chunk {id, part}`. Stored parts expire after 5 minutes.

## Scoping and binding

Every method except `ping`, `echo`, `get_chunk` and `bind` must carry `companion` (the character name) and `session` (the MCP instance's token). The mod checks that this session holds the binding, then refreshes the lease. Calls from anything else fail with `this MCP session does not hold character …`.

| Method | Params | Result |
|---|---|---|
| `bind` | `{name, session, takeover?}` | Claims the character. Refused if another session called within 60 s, unless `takeover: true`. Spawns the body at the force spawn point if missing (freeplay `created_items` kit on first creation). Returns `{name, position, surface, already_existed, took_over, kit?}` |
| `heartbeat` | — | No-op that refreshes the lease. The server sends it every 20 s |
| `unbind` | — | Releases the binding and leaves the body in the world. Sent on shutdown |
| `respawn` | — | New body after death (freeplay `respawn_items` kit) |
| `retire` | — | Removes the character entirely: body with inventory, jobs, binding. Used for test cleanup |

## Perception (instant)

All results are filtered by fog of war (`scripts/vision.lua`):
- **KNOWN:** chunks explored by the force's agent characters (5×5 chunks around each), or charted by the force.
- **VISIBLE:** within 32 tiles of any force member, or in a radar-visible chunk.

| Method | Notes |
|---|---|
| `get_state {radius≤80}` | The character, other agent characters, players, resource patches and trees (known ground), own buildings with status histograms, visible enemies, research, power, top production, `explored_chunks` |
| `check_inventory` | Own inventory and equipment. Keys are `name`, or `name@quality` for non-normal quality |
| `inspect {position} \| {targets≤16}` | Target must be known. Entities of other forces must be visible |
| `analyze_factory {radius}` | Own machines on known ground, grouped by problem |
| `scan_area {center?, radius≤30}` | ASCII grid; unknown tiles are `?` |
| `can_place {item, position, direction} \| {placements≤24}` | Position must be known |
| `find_buildable_area {width, height, near, max_distance}` | Known ground only |
| `describe_prototype {names≤10}` | Static prototype data |
| `production_stats {window, names?, kind?, top?}` | Force item and fluid flows on the character's surface. `window` ∈ 5s, 1m, 10m, 1h, 10h, 50h, 250h, 1000h. Returns `produced_per_min`, `consumed_per_min`, `net_per_min` and all-time totals |
| `list_trains`, `list_blueprints`, `read_blueprint`, `import_blueprint {string}` | Blueprints: only ones the character carries, or export strings |
| `export_blueprint {area: [{x,y},{x,y}]}` | Own buildings in a known area of at most 200×200 tiles. Returns `{string, entity_counts, total_entities, size, anchor}` |
| `get_chat {since_id}` | Everything after the cursor except this character's own lines. Agent lines have `bot: true` |
| `get_events {since_id}` | Events for this character plus force-wide ones (`job_done`, `job_failed`, `attacked`, `died`, `research_finished`, `supply_warning`) |

| `route_belt {from, to, belt?, allow_underground?, clear_obstacles?, margin?, avoid?, planned_belts?}` | Plans one belt line on known ground (see `scripts/route/`). An endpoint is `{x, y, direction?, port}` with `port` ∈ `tile`, `drop`, `pickup`, `belt` or `fluid` (inserter/drill drop tile, inserter pickup tile, join an existing belt). `allow_underground` nil means: if carried or the recipe is enabled. The search box is the endpoints' bounding box plus `margin` (2–40), at most 160 tiles a side. Returns `steps [{item, x, y, direction, underground_type?}]`, `bill`, `missing`, `unavailable`, `mine_first` (trees and rocks on the path), `effects` (what joining the target belt does), `length`, `turns`, `underground_pairs`, `expansions`. No side effects: the MCP server turns the steps into mine and `build_plan` jobs when `build=true` |
| `route_pipe {…}` | The same for pipes and pipe-to-ground. It never runs next to a foreign fluid connection, so fluids don't mix |

## Instant actions

`say {text}`, `start_research {technology}`, `equip {gun?, ammo?, armor?}`, `exit_vehicle`, `set_train_schedule {train_id, stops}`.

## Jobs

| Method | Params | Result |
|---|---|---|
| `enqueue` | `{task, replace?, quiet?, chain?}` | `{task_id, cancelled?}` |
| `get_task` | `{task_id}` | `{status, detail, type}` for **own** jobs only. Status is one of queued, running, done, failed, cancelled |
| `list_tasks` | `{limit?}` | Own `active`, `queued`, and `recent` (finished within 5 minutes) |
| `cancel` | `{task_id}` or `{all: true}` | Own jobs only; cancelling another character's job raises an error |

Each character has one lane, a FIFO queue plus the active job, and lanes tick in parallel.
- **`replace`** cancels the lane first.
- **`chain`:** when a step of a chain fails, the rest of the chain is cancelled.
- **`quiet`** suppresses the `job_done` event.

Task types:
- movement: `walk_to`, `drive_to`, `follow_player`
- resources and crafting: `mine`, `craft`
- placing and configuring: `place`, `rotate`, `set_recipe`
- inventory transfers: `insert`, `extract`
- building: `build_plan`, `build_blueprint`, `deconstruct`
- combat and upkeep: `fight`, `defend_area`, `keep_fueled`

Every task with a map target walks within reach first, and each movement goal is checked against the exploration rule.

### Map overview

`map_overview {center?, radius≤640}` visits every KNOWN chunk in the square once. It counts resources by name, rocks, trees, water tiles and enemy spawners and worms, then groups each category into 4-connected chunk components. It returns `{known_chunks, total_chunks, groups: [{kind, count, chunks, center, at, area, distance}], more}`, nearest first (at most 60). `at` is a real tile of the patch.

**Starting area:** when an agent character first spawns or binds, the force's explored set gains every chunk within `factorio-mcp-start-area` tiles (default 200) of spawn, the area freeplay charts for a new player.

### Build checks

`layout_context {area: [x1, y1, x2, y2], points: [{x, y}, …]}` returns `{belts: [{x, y, direction, type, name, underground_type?}], at: [name | "nothing" | "unexplored"]}`. It's read-only and uses known ground only (at most 200×200 tiles, 400 points).

The server combines it with the plan's own entities (`checks.py`):
- belt dead ends next to an input-less line;
- belts facing each other;
- each inserter's pickup and drop entity, with a warning when it picks from nothing or from a chest placed in the same plan.

### Idempotent enqueue

`enqueue {…, request_id}`: the mod remembers each `request_id` for 5 minutes. A repeat (the client retrying after a lost reply) returns the job the first attempt created, with `duplicate: true`. The server sends a fresh `request_id` with every enqueue.

### wait_until

`{type: "wait_until", seconds}`, `{type: "wait_until", item, count, at?}` or `{type: "wait_until", research}`, plus an optional `timeout_s` (default 300). Checked every 30 ticks. It fails with "timed out waiting for …" when the time runs out.

### Optional jobs

`enqueue {…, optional: true}`:
- A failure of this job doesn't mark its chain failed, so later jobs still run. It emits `optional_job_failed` instead of `job_failed`.
- It is still cancelled when an earlier job of its chain fails.

### Queue-ahead (server side)

- **One chain per character.** The MCP server passes one `chain` id with every job of its character: single tools, `run_plan` steps and route builds alike.
- **Failure handling.** When a chained job fails, the mod cancels the queued jobs of that chain and remembers the chain as failed. A late enqueue for that chain is cancelled at once (`{cancelled: true}`).
- **After a failure.** The server starts a new chain as soon as it has told the agent about the failure, by any of:
  - a `job_failed` event in a result footer;
  - a failed or cancelled wait;
  - a cancelled enqueue;
  - `job_cancel all`;
  - `replace=true`.
- **Footers.** Every tool result (except `read_chat`, `wait_for_events` and `status`) ends with the `get_events` and `get_chat` entries since the character's cursors. Reading advances the cursors, so each entry is shown once.

## Fairness rules enforced mod-side

- **Movement:** `request_path` plus `walking_state`, with running-speed modifiers held at 0.
- **Hand mining and deconstruction:** `mining_time / (0.5 × (1 + force bonus + character bonus))`, reach checked. Mined items are recorded in production statistics.
- **Crafting:** only through `begin_crafting`, the real queue with real time.
- **Placement:** build range, `can_place_entity` with the manual build check, and the item is consumed from the character's inventory (with quality).
- **Transfers:** reach checked, and item counts are conserved.
- **Starting items:** only the freeplay scenario's kits.
