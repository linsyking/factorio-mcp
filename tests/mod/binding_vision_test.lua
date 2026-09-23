-- Offline tests for the fork's own mechanisms: session binding (companion.lua),
-- fog of war (vision.lua), quality item keys (items.lua) and per-character job
-- isolation (tasks.lua). Run: lua tests/mod/binding_vision_test.lua
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end
local function raises(fn, pattern)
  local ok, err = pcall(fn)
  return (not ok) and (pattern == nil or tostring(err):find(pattern, 1, true) ~= nil), err
end

-- ------------------------------------------------------------ game stubs
local charted = {}  -- "cx,cy" -> true  (force charting, e.g. by a human)
local force = { index = 1, name = "player", connected_players = {} }
function force.get_spawn_position() return { x = 0, y = 0 } end
function force.is_chunk_charted(_, c) return charted[c[1] .. "," .. c[2]] == true end
function force.is_chunk_visible() return false end

local surface = { index = 1, name = "nauvis" }
local unit = 0
local inserted = {}
function surface.find_non_colliding_position(_, anchor) return { x = anchor.x, y = anchor.y } end
function surface.request_to_generate_chunks() end
function surface.create_entity(args)
  unit = unit + 1
  local e = { valid = true, unit_number = unit, position = { x = args.position.x, y = args.position.y },
    surface = surface, force = force, character_running_speed_modifier = 0.6 }
  function e.insert(stack) inserted[#inserted + 1] = stack; return stack.count end
  return e
end

_G.game = { tick = 1000, forces = { player = force }, surfaces = { nauvis = surface, [1] = surface } }
_G.storage = {}
_G.settings = { global = { ["factorio-mcp-start-area"] = { value = 0 } } } -- fog tests start from nothing
_G.rendering = { draw_text = function() return { valid = true, destroy = function() end } end }
_G.prototypes = { item = { pistol = {}, ["iron-plate"] = {} }, quality = { normal = {}, rare = {} } }
_G.remote = {
  interfaces = { freeplay = { get_created_items = true, get_respawn_items = true } },
  call = function(_, fn)
    if fn == "get_created_items" then return { ["iron-plate"] = 8, pistol = 1 } end
    return { pistol = 1 }
  end,
}

local companion = require("scripts.companion")
local vision = require("scripts.vision")
local items = require("scripts.items")

-- -------------------------------------------------------------- binding
do
  local body = companion.bind({ name = "scout-1", session = "session-aaaa" })
  check(body.bound and not body.already_existed, "bind: creates the character on first bind")
  local ent = companion.get("scout-1")
  check(ent.character_running_speed_modifier == 0, "bind: no speed modifier on the body")
  check(body.kit and body.kit["iron-plate"] == 8, "bind: gets the freeplay created_items kit")

  check(raises(function() companion.bind({ name = "scout-1", session = "session-bbbb" }) end, "bound to another live"),
    "bind: a second live session is refused")
  local b2 = companion.bind({ name = "scout-1", session = "session-bbbb", takeover = true })
  check(b2.took_over == true and b2.already_existed == true, "bind: explicit takeover works and keeps the body")
  check(raises(function() companion.touch("scout-1", "session-aaaa") end, "does not hold"),
    "touch: the old session loses the character")
  companion.touch("scout-1", "session-bbbb")
  check(true, "touch: the new session holds it")

  game.tick = game.tick + 60 * 61 -- lease expires
  local b3 = companion.bind({ name = "scout-1", session = "session-cccc" })
  check(b3.took_over == true, "bind: an idle session (>60 s) may be taken over without the flag")

  check(raises(function() companion.bind({ name = "bad/name", session = "session-dddd" }) end, "may only contain"),
    "bind: rejects odd character names")
end

-- ------------------------------------------------------------ fog of war
do
  local ent = companion.get("scout-1")
  ent.position = { x = 10, y = 10 } -- chunk (0,0)
  vision.mark(ent) -- radius 2 -> chunks -2..2
  check(vision.is_known(surface, force, { x = 70, y = 70 }), "vision: chunk (2,2) explored around the character")
  check(not vision.is_known(surface, force, { x = 200, y = 0 }), "vision: chunk (6,0) unexplored")
  charted["6,0"] = true
  check(vision.is_known(surface, force, { x = 200, y = 0 }), "vision: force-charted chunks count as known")

  local list = {
    { valid = true, position = { x = 5, y = 5 }, force = force },
    { valid = true, position = { x = 500, y = 500 }, force = force },
  }
  check(#vision.filter_known(list, surface, force) == 1, "vision: filter_known drops entities on unexplored ground")

  local enemy = { name = "enemy" }
  local near = { valid = true, position = { x = 20, y = 10 }, force = enemy }
  local far = { valid = true, position = { x = 60, y = 60 }, force = enemy } -- known chunk, but > 32 tiles away
  local seen = vision.filter_perceivable({ near, far }, surface, force)
  check(#seen == 1 and seen[1] == near, "vision: enemies only while within view radius")

  check(not raises(function() vision.check_walk_goal(ent, { x = 60, y = 60 }) end),
    "vision: walking to explored ground is allowed")
  ent.position = { x = 10, y = -60 } -- near the northern edge of explored ground
  check(not vision.is_known(surface, force, { x = 10, y = -100 }), "vision: (10,-100) is unexplored")
  check(not raises(function() vision.check_walk_goal(ent, { x = 10, y = -100 }) end),
    "vision: a 40-tile step into unexplored land is allowed (exploring)")
  check(raises(function() vision.check_walk_goal(ent, { x = 10, y = -400 }) end, "unexplored"),
    "vision: far unexplored goals are refused")
end

-- --------------------------------------------------------- quality keys
do
  check(items.key("iron-plate", "normal") == "iron-plate", "items: normal quality keeps the plain name")
  check(items.key("iron-plate", { name = "rare" }) == "iron-plate@rare", "items: other quality becomes name@quality")
  local n, q = items.parse("iron-plate@rare")
  check(n == "iron-plate" and q == "rare", "items: parse name@quality")
  local n2, q2 = items.parse("iron-plate")
  check(n2 == "iron-plate" and q2 == "normal", "items: parse plain name")
  local map = items.inventory_map({ get_contents = function()
    return { { name = "iron-plate", count = 5, quality = "normal" }, { name = "iron-plate", count = 2, quality = "rare" } }
  end })
  check(map["iron-plate"] == 5 and map["iron-plate@rare"] == 2, "items: inventory_map keeps qualities apart")
end

-- -------------------------------------------------- job isolation (tasks)
do
  package.loaded["scripts.events"] = { push = function() end }
  local runner = { start = function() end, tick = function() return nil end }
  for _, m in ipairs({ "walk", "follow", "mine", "build", "craft", "transfer", "refuel",
    "drive", "build_plan", "deconstruct", "fight", "defend", "build_blueprint" }) do
    package.loaded["scripts.actions." .. m] = runner
  end
  runner.place, runner.rotate, runner.set_recipe, runner.insert, runner.extract = runner, runner, runner, runner, runner
  _G.defines = { shooting = { not_shooting = 0 } }
  storage.tasks = { next_id = 1, records = {}, by_companion = {}, failed_chains = {} }
  companion.bind({ name = "builder-1", session = "session-eeee" })
  local tasks = require("scripts.tasks")

  companion.set_context("scout-1")
  local a = tasks.enqueue({ task = { type = "walk_to" } })
  companion.set_context("builder-1")
  local b = tasks.enqueue({ task = { type = "mine" } })
  tasks.on_tick()
  companion.set_context("builder-1")
  check(tasks.get({ task_id = b.task_id }).status == "running", "jobs: own job visible")
  check(raises(function() tasks.get({ task_id = a.task_id }) end, "doesn't belong"),
    "jobs: another character's job is not readable")
  check(raises(function() tasks.cancel({ task_id = a.task_id }) end, "doesn't belong"),
    "jobs: another character's job can't be cancelled")
  local l = tasks.list({})
  check(l.active and l.active.id == b.task_id, "jobs: list shows only the own running job")
  local c = tasks.cancel({ all = true })
  companion.set_context("scout-1")
  check(c.cancelled == 1 and tasks.get({ task_id = a.task_id }).status == "running",
    "jobs: cancel all only clears the own lane (both lanes ran in parallel)")
end

do -- the starting area: agents know the ground around spawn, like a new player's map
  settings.global["factorio-mcp-start-area"] = { value = 200 }
  local f2 = { index = 99, is_chunk_charted = function() return false end }
  local s2 = { index = 7, request_to_generate_chunks = function() end, is_chunk_generated = function() return true end }
  check(not vision.is_known(s2, f2, { x = 150, y = -150 }), "start area: unknown before it is granted")
  vision.grant_start_area(s2, f2, { x = 0, y = 0 })
  check(vision.is_known(s2, f2, { x = 150, y = -150 }), "start area: 150 tiles from spawn is known")
  check(not vision.is_known(s2, f2, { x = 300, y = 0 }), "start area: 300 tiles from spawn is still unexplored")
  check(#vision.known_chunks(s2, f2, -40, -40, 40, 40) == 16, "start area: known_chunks lists the chunks a rectangle touches (4x4)")
  settings.global["factorio-mcp-start-area"] = { value = 0 }
end

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
