# Protocol v5: MCP server ↔ game mod

`ping` returns `protocol_version: 5`. The MCP server refuses to bind when the versions differ.

## Transport

Every call is one RCON command:

```
/silent-command remote.call("factorio_mcp","rpc","<method>","<params as escaped JSON string>")
```

- **Params:** always a JSON **string**; the server escapes `\` and `"`.
- **Replies:** the mod answers on the same RCON response with `rcon.print(json)`.
- **Sentinel:** the RCON client sends a sentinel command (a single space) after every command. Factorio splits replies larger than about 4 kB into packets that share one id and have no terminator; the sentinel's reply marks the end.

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

## Fairness rules enforced mod-side

- **Movement:** `request_path` plus `walking_state`, with running-speed modifiers held at 0.
- **Hand mining and deconstruction:** `mining_time / (0.5 × (1 + force bonus + character bonus))`, reach checked. Mined items are recorded in production statistics.
- **Crafting:** only through `begin_crafting`, the real queue with real time.
- **Placement:** build range, `can_place_entity` with the manual build check, and the item is consumed from the character's inventory (with quality).
- **Transfers:** reach checked, and item counts are conserved.
- **Starting items:** only the freeplay scenario's kits.
