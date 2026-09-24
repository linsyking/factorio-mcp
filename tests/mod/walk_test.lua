-- Offline tests for scripts/actions/walk.lua: the pathfinder walker.
-- Bug A: a slow pathfinder answer used to be dropped after 1.5 s (straight-line fallback).
-- Bug B: sliding along a shore never counted as stuck, so the walk never ended.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

_G.defines = { direction = { north = 0, northeast = 2, east = 4, southeast = 6, south = 8, southwest = 10, west = 12, northwest = 14 } }
_G.game = { tick = 0 }
_G.prototypes = { entity = { character = { collision_mask = {} } } }
_G.storage = { path_requests = {}, tasks = { by_companion = {} } }
package.loaded["scripts.companion"] = { context = function() return "w" end }
package.loaded["scripts.vision"] = { check_walk_goal = function() end }

local walk = require("scripts.actions.walk")

local UNIT = { [0] = { 0, -1 }, [2] = { 0.7071, -0.7071 }, [4] = { 1, 0 }, [6] = { 0.7071, 0.7071 },
  [8] = { 0, 1 }, [10] = { -0.7071, 0.7071 }, [12] = { -1, 0 }, [14] = { -0.7071, -0.7071 } }

-- A character on a surface with an optional wall: x >= wall_x can't be entered;
-- pushing into it slides north along it (like a shoreline).
local next_id = 0 -- request ids are unique across the game, like LuaSurface.request_path's
local function make_char(x, y, wall_x)
  local c = { position = { x = x, y = y }, walking_state = { walking = false }, force = {} }
  c.requests = {}
  c.surface = {
    request_path = function(spec)
      next_id = next_id + 1
      c.requests[#c.requests + 1] = next_id
      c.flags = c.flags or {}
      c.flags[#c.flags + 1] = spec.pathfind_flags
      return next_id
    end,
    can_place_entity = function() return true end,
  }
  function c.move()
    local ws = c.walking_state
    if not ws.walking then return end
    local u = UNIT[ws.direction]
    local nx, ny = c.position.x + u[1] * 0.15, c.position.y + u[2] * 0.15
    if wall_x and nx >= wall_x then
      nx, ny = c.position.x, c.position.y - 0.15 -- slide along the wall
    end
    c.position = { x = nx, y = ny }
  end
  return c
end

local function run(state, c, ticks)
  for _ = 1, ticks do
    game.tick = game.tick + 1
    local r = walk.step(state, c, 1)
    c.move()
    if r ~= nil then return r end
  end
  return nil
end

local function answer(id, points)
  local path
  if points then
    path = {}
    for i, p in ipairs(points) do path[i] = { position = { x = p[1], y = p[2] } } end
  end
  walk.on_path_finished({ id = id, path = path })
end

-- 1. Bug A: a slow answer is waited for (the engine always answers), and used
do
  local c = make_char(0.5, 0.5)
  local st = {}
  walk.begin(st, c, { x = 40.5, y = 0.5 }, 1)
  local r = run(st, c, 60 * 60) -- a whole minute without an answer
  check(r == nil and st.phase == "waiting" and math.abs(c.position.x - 0.5) < 1e-9 and #c.requests == 1,
    "slow pathfinder: after 60 s the walker still waits for its one request, standing still (no blind straight line)")
  check(c.flags[1].cache == true, "requests use the engine's path cache")
  answer(c.requests[1], { { 20.5, 0.5 }, { 40.5, 0.5 } })
  r = run(st, c, 60 * 60)
  check(r == "arrived", "slow pathfinder: the late answer is used and the character arrives")
end

-- 2. an answer that never comes (lost): the 2-minute watchdog asks again once, then fails
do
  local c = make_char(0.5, 0.5)
  local st = {}
  walk.begin(st, c, { x = 80.5, y = 0.5 }, 1)
  _G.log = function() end
  local r = run(st, c, 245 * 60)
  check(#c.requests == 2, "lost answer: the watchdog repeats the request once")
  check(type(r) == "table" and r.failed:find("didn't answer", 1, true), "no answer: fails with a reason instead of hanging")
end

-- 3. "no path" for a far goal fails at once; a short hop is walked straight
do
  local c = make_char(0.5, 0.5)
  local st = {}
  walk.begin(st, c, { x = 90.5, y = 0.5 }, 1)
  run(st, c, 2)
  answer(c.requests[1], nil)
  local r = run(st, c, 5)
  check(type(r) == "table" and r.failed:find("no path", 1, true), "no path, far goal: fails with the reason")

  local c2 = make_char(0.5, 0.5)
  local st2 = {}
  walk.begin(st2, c2, { x = 8.5, y = 0.5 }, 1)
  run(st2, c2, 2)
  answer(c2.requests[1], nil)
  local r2 = run(st2, c2, 20 * 60)
  check(r2 == "arrived", "no path, short hop: walked straight and arrived")
end

-- 4. Bug B: sliding along a wall/shore (moving, never closer) ends in a failure
do
  local c = make_char(0.5, 0.5, 5)
  local st = {}
  walk.begin(st, c, { x = 12.5, y = 0.5 }, 1)
  run(st, c, 2)
  answer(c.requests[#c.requests], nil) -- no path → short hop straight into the wall
  local r
  for _ = 1, 10 do -- answer every re-path with "no path" too
    r = run(st, c, 60 * 60)
    if r ~= nil then break end
    answer(c.requests[#c.requests], nil)
  end
  check(type(r) == "table" and r.failed:find("getting no closer", 1, true),
    "sliding along a wall: fails ('moving but getting no closer') instead of running forever")
  check(c.flags[#c.flags].cache == false, "the re-path after getting stuck bypasses the path cache")
  check(c.position.y > -15, "sliding along a wall: noticed after ~11 tiles of sliding (off course), not 54+")
end

-- 5. results are kept per request: two walkers asking at once both get their own answer
do
  local c1, c2 = make_char(0.5, 0.5), make_char(0.5, 3.5)
  local s1, s2 = {}, {}
  walk.begin(s1, c1, { x = 30.5, y = 0.5 }, 1)
  walk.begin(s2, c2, { x = 30.5, y = 3.5 }, 1)
  game.tick = game.tick + 1
  walk.step(s1, c1, 1)
  walk.step(s2, c2, 1)
  -- c2's answer first, in the same tick as c1's
  answer(c2.requests[1], { { 30.5, 3.5 } })
  answer(c1.requests[1], { { 30.5, 0.5 } })
  local r1, r2
  for _ = 1, 30 * 60 do
    game.tick = game.tick + 1
    r1 = r1 or walk.step(s1, c1, 1)
    r2 = r2 or walk.step(s2, c2, 2)
    c1.move() c2.move()
    if r1 and r2 then break end
  end
  check(r1 == "arrived" and r2 == "arrived", "two walkers: answers are routed by request id; both arrive")
end

-- 6. an answer to a replaced request is ignored
do
  local c = make_char(0.5, 0.5)
  local st = {}
  walk.begin(st, c, { x = 40.5, y = 0.5 }, 1)
  run(st, c, 121 * 60) -- first request's answer is lost; the watchdog sends a second
  answer(c.requests[1], { { -30, 0.5 } }) -- stale answer for the first request
  check(storage.path_results[c.requests[1]] == nil, "stale answers (replaced request) are dropped")
  answer(c.requests[2], { { 40.5, 0.5 } })
  check(run(st, c, 30 * 60) == "arrived", "the current request's answer is used")
end

-- 7. the pathfinder budget setting raises the engine's per-tick limits
do
  _G.game.map_settings = { path_finder = { max_steps_worked_per_tick = 1000, max_work_done_per_tick = 8000 } }
  _G.settings = { global = { ["factorio-mcp-pathfinder-budget"] = { value = 4 } } }
  walk.apply_pathfinder_budget()
  local pf = game.map_settings.path_finder
  check(pf.max_steps_worked_per_tick == 4000 and pf.max_work_done_per_tick == 32000, "budget: 4x the vanilla pathfinder work per tick")
  settings.global["factorio-mcp-pathfinder-budget"].value = 1
  walk.apply_pathfinder_budget()
  check(pf.max_steps_worked_per_tick == 1000, "budget: 1 restores vanilla")
end

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
