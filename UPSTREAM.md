# Upstream

factorio-mcp is a fork of **[matteomekhail/Agentic-Factorio](https://github.com/matteomekhail/Agentic-Factorio)**, which is MIT licensed (declared in its `package.json`). The fork point is commit `158dee7` ("merge: faster multi-agent gameplay", 2026-07-16).

- **Kept, with changes:** the Lua mod (`mod/agentic-companion` became `mod/factorio-mcp`).
- **Replaced:** the TypeScript companion app. The machine this was built on has no Node.js, so the MCP server was rewritten in Python using the official MCP SDK 2.x. The envelope and chunking protocol and the text formatters were ported from the TypeScript code. The RCON sentinel technique was ported too, then dropped: with a player connected, Factorio can answer pipelined commands out of order, so the sentinel's reply overtook `bind` replies and they read as empty. The client now sends one command and waits for the packet with its id.

## Removed

| Removed | Why |
|---|---|
| AI chat loop, Codex brain, setup wizard, telemetry, the `play` prompts | Agent-side concerns; the MCP only provides capabilities |
| Coordination broker: `coordinate_*_job` tools, `assertMayAct`, `agent_id` | Orchestration policy belongs on the agent side |
| Per-call `companion` parameter and 4-companion cap | 1 agent ↔ 1 MCP instance ↔ 1 character; the character is bound at startup, with up to 32 characters by default (mod setting) |
| 1.6× movement-speed setting | Fairness: normal walking speed only |
| `deliver_items`; reading players' inventories and cursors | Fairness: things a player can't do |
| Starter blueprint books (Nilaus etc.) | License unclear, and they were free items |
| `view_area` / screenshots | The renderer doesn't work on a headless server |
| Consent flag on `deconstruct`, advice in tool descriptions and events ("decide: fight back…", "tip: …") | Policy-free: tools describe what they do, not when to use them |

## Added

- **Binding:** each MCP instance binds one named character with a session token and a lease. Takeover is explicit, and a heartbeat keeps the lease alive. The mod refuses a second live session for the same character.
- **Fog of war** (`scripts/vision.lua`): the mod keeps its own explored-chunk set, because the engine never charts for characters without a player. Every perception query is filtered by it:
  - terrain, resources and own buildings only on explored or charted ground;
  - enemies only while visible;
  - walk goals must be explored or within 64 tiles.
- **Jobs:** every multi-tick action returns a job id; the tool waits up to `wait_s`. `job_status`, `job_wait` and `job_cancel` work on your character only. Each character has its own lane, and different characters' jobs run in parallel.
- **Per-character event and chat logs**, read with cursors so reading never consumes them. Agents hear each other's chat.
- **`production_stats`:** item **and fluid** rates over any statistics window.
- **`export_blueprint`:** capture an explored area as a blueprint string.
- **`build_blueprint` from an export string.**
- **`build_plan dry_run`:** item bill against inventory, recipe checks, placement, and overlaps between steps.
- **Quality:** item keys `name@quality` in inventories, insert/extract and placement.
- **Freeplay start and respawn kits** from the scenario, so a new agent starts like a new player.
- **`retire`** (test cleanup), a CLI (`doctor`, `call`, `tools`, `retire`, `package-mod`), `scripts/deploy_mod.sh`, and tests (Lua unit, pytest, live multi-agent).

- **Queue-ahead jobs:** job tools return at once by default. All of a character's jobs share one chain, so a failure cancels everything queued behind it.
- **News footer:** every tool result ends with finished or failed jobs, events and unread chat since the previous call.

- **Build checks** (`checks.py`, `layout_context` RPC): belt-flow and inserter-end warnings in `build_plan`, `drop_to` / `pickup_from` for inserters, arrows for belts in `scan_area`.
- **Watching:** in-game `/follow`, `/follow-cam`, `/follow-cams` and `/unfollow`. `set_status` plus job progress gives a status line under each agent's name and camera.
- **A bigger view:** `map_overview` (chunk-resolution map of all known ground). Agents start knowing ±200 tiles around spawn, like a new freeplay player (mod setting `factorio-mcp-start-area`). `look_around` goes to 150 tiles, `scan_area` to radius 120 (downsampled), and `mine`'s search to 200.
- **Belt lanes:** `inspect_entity` on a belt reports each lane (left/right of travel, with the compass side).
- **Optional jobs, stop-on-failure batches, per-step `run_plan` results, strict tool arguments.**
- **Engine mining:** hand-mining uses the engine's own mining (selected entity + `mining_state`). The character shows the mining animation, and timing and production statistics are vanilla. A script timer is the fallback when the engine can't be pointed at exactly the target.

## Fixed: walker hangs under load (mod 0.2.10, from an agent's report)

- **The pathfinder's answer is waited for; it always comes.** The engine answers every `request_path` exactly once (`on_script_path_request_finished`: a path, no path, or "try again later"), however long it takes. The walker used to give up after 1.5 s and walk blindly; under a six-character load valid paths hadn't arrived yet, and late answers were dropped.
  - Now it waits, standing still, with no timeout for slowness.
  - Answers could only get lost through our own bookkeeping: `state.init` wiped pending requests on every mod update. It keeps them now.
  - A 2-minute watchdog re-asks once, as a safety net that should never fire.
  - "No path", or a pathfinder that stays busy, ends the walk with the reason. Only a hop of 16 tiles or less may still be walked straight (the goal may itself be blocked, e.g. a rock).
- **Faster answers.**
  - The mod setting `factorio-mcp-pathfinder-budget` (default 4, 1 = vanilla) multiplies the engine's per-tick pathfinder work. Vanilla expands 1000 nodes per tick for every character and biter together. This changes map settings.
  - Requests use the engine's path cache again; only a re-path after getting stuck bypasses it.
  - The status line shows "waiting for a path (N s)".
- **Answers are stored by request id** (`storage.path_results`). Two walkers of one task (approach, then step aside) no longer take or overwrite each other's answer; answers nobody collects expire after 10 minutes.
- **A walk always ends.** Besides "not moving", it now also counts as stuck when it gets no closer to its current waypoint for 6 s, or when it drifts 3+ tiles farther away (sliding along a shore or wall). After one re-path it fails ("moving but getting no closer"). There is also a deadline of 4× the straight-line walking time + 30 s from when it starts moving.

## Fixed from an agent's bug report (mod 0.2.9)

- A `place` step's `recipe` is applied, and checked before walking. It used to be silently ignored.
- A failure shown by `get_events` or `wait_for_events` counts as acknowledged, so the next job starts a new queue instead of being refused.
- A map point resolves to the entity whose footprint contains it, not the nearest centre. A point on the edge between two buildings, or two batch targets hitting the same entity, is reported in the result. This applies to inspect, insert, extract, rotate and set_recipe.
- A lost binding (after a takeover, for example) re-binds and repeats the call once. Tools that used the bridge directly used to keep failing until the next heartbeat.
- After a dropped RCON connection, calls are retried when safe (for up to about 17 s, which covers a server restart): always if the command never reached the server, and otherwise only read-only calls and `enqueue`, which the mod de-duplicates by `request_id`. Other calls report that they "may or may not have run".
- `describe_prototype` lists fluid connection points (side, pipe offset, flow). `inspect_entity` lists each connection's map position and whether it's connected.
- New `wait_until` job (tool and `run_plan` step).
- The offshore-pump placement message says which directions fit, instead of "the footprint touches water".
- No energy value for void-powered entities; `scan_area` letters are shared by the whole force; `craft_items`' `count` is documented as recipe executions.

## Fixed after the collaboration and solo tests (research/factorio-agent/12, 13)

- Whole-number positions of odd-sized entities are snapped to the tile centre (a belt at (92,−12) used to "fail unexpectedly").
- `auto_craft` crafts ⌈missing / products per craft⌉ times (it used to make 18 spare belts for 18 placements).
- Placing steps out of the footprint first when the character stands in it.
- `walk_to` a blocked goal (a rock, a building) ends next to it instead of "stuck".
- `read_chat` has `include_self` for full transcripts.
- Clearer tool descriptions: what `mine`'s `count` means for rocks, inserter directions, and that `wait_for_events` returns at the first news.

## Fixed

- **Hand-mining was 2× too fast.** Upstream used `mining_time × 60 / (1 + bonus)` and ignored the character's base mining speed of 0.5. Mining and deconstruction now use the vanilla formula; measured 0.496 iron ore/s.
- **Missing production statistics.** Script mining and crafting by player-less characters weren't recorded; they are now logged with `on_flow`, as a player's would be.
- **`build_blueprint` reported failure.** It never initialised `_auto_crafted`, so it compared `nil > 0`.
- **Cancelling another character's running job** silently returned 0; it now refuses.
- **Lua file and line prefixes** are stripped from error messages.

## Fixed after the acceptance test (research/factorio-agent/10)

- **`describe_prototype`** returns every view of a name — item, entity and recipe — plus power in kW, fuel value, stack size, crafting and mining speed, mining area, module slots, inventory slots and belt throughput.
- **`analyze_factory`** accounts for every entity: working, with problems (now including drills waiting for space in their destination), or in other states.
- **`can_place`, `place_entity` and `build_plan`** share one explanation module (`placement.lua`), which names a drill placed without ore, water, a blocking entity, or the character itself.
- **The `build_plan` dry run** counts `insert` quantities in the item bill.
- **`scan_area`** keeps each character's letters stable across scans and paints your buildings' full footprint.
- **Chat and event read cursors** are stored per character in the mod, so a new MCP session continues where the previous one stopped.
- **`inspect_entity`** reports the energy buffer in kJ, the fuel being burned, and the ore left in a drill's mining area.
- **The `factorio-mcp tools` listing** shows every parameter's type, limits and default.
