-- walk_to + reusable pathfinder walker. Other actions embed the walker via
-- M.begin/M.step (plain-data state, storage-safe). Pathfinder results arrive
-- through on_script_path_request_finished → M.on_path_finished (wired in
-- control.lua); storage.path_requests maps request id → task id.
local companion = require("scripts.companion")
local vision = require("scripts.vision")

local M = {}

local WAYPOINT_RADIUS_SQ = 0.25 -- advance to the next waypoint within 0.5 tiles
local STUCK_CHECK_TICKS = 60
local STUCK_EPSILON_SQ = 0.01 -- moved less than 0.1 tiles in a check window = stuck
-- The engine answers every request_path exactly once (a path, no path, or
-- "try again later") via on_script_path_request_finished, however long it
-- takes under load — so the walker waits for that answer instead of timing
-- out, standing still while it waits. Answers can only be lost if our own
-- bookkeeping is (it survives mod updates, see state.lua); the watchdog below
-- is a safety net for that, not a timeout for slow answers.
local WATCHDOG_TICKS = 120 * 60   -- no answer after 2 min: something lost it → ask again
local MAX_REQUESTS = 2            -- …then fail (or walk straight if the goal is close)
local RETRY_DELAY_TICKS = 60      -- pathfinder busy ("try again later") → ask again after 1 s
local MAX_RETRIES = 10
local STRAIGHT_MAX_DIST = 16      -- only a short hop may be walked without a path
-- Progress: sliding along a shore or wall keeps the character moving, so
-- "not moving" alone never fires. Fail (after one re-path) when the walker
-- gets no closer to its current goal for this long, and always by a deadline.
local NO_PROGRESS_TICKS = 6 * 60
local PROGRESS_MIN = 0.5          -- tiles closer than the best so far
local OFF_COURSE_TILES = 3        -- this much farther than the best so far: sliding away (a path leg never recedes)
local SPEED_TILES_PER_TICK = 0.15 -- character running speed
local DEADLINE_FACTOR, DEADLINE_SLACK_TICKS = 4, 30 * 60
local RESULT_TTL_TICKS = 10 * 60 * 60

-- tan(22.5 deg): boundary between cardinal and diagonal octants
local OCTANT_RATIO = 0.41421356

-- Map coordinates: +x east, +y south.
local function direction_toward(from, to)
  local dx, dy = to.x - from.x, to.y - from.y
  local adx, ady = math.abs(dx), math.abs(dy)
  if adx < OCTANT_RATIO * ady then
    return dy >= 0 and defines.direction.south or defines.direction.north
  end
  if ady < OCTANT_RATIO * adx then
    return dx >= 0 and defines.direction.east or defines.direction.west
  end
  if dx >= 0 then
    return dy >= 0 and defines.direction.southeast or defines.direction.northeast
  end
  return dy >= 0 and defines.direction.southwest or defines.direction.northwest
end
M.direction_toward = direction_toward

local function dist_sq(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

local function results()
  storage.path_results = storage.path_results or {}
  return storage.path_results
end

local function request_path(state, c, task_id)
  -- a newer request replaces this walker's pending one: nobody wants that answer
  if state.request_id then storage.path_requests[state.request_id] = nil end
  local id = c.surface.request_path({
    bounding_box = { { -0.2, -0.2 }, { 0.2, 0.2 } },
    collision_mask = prototypes.entity["character"].collision_mask,
    start = c.position,
    goal = state.target,
    force = c.force,
    radius = math.max(state.arrive_within, 0.5),
    can_open_gates = true,
    entity_to_ignore = c,
    path_resolution_modifier = 0,
    -- the engine's path cache answers repeat trips fast; a re-path after
    -- getting stuck bypasses it to see new obstacles
    pathfind_flags = { cache = not state.no_cache, prefer_straight_paths = true },
  })
  storage.path_requests[id] = { name = companion.context(), task_id = task_id, tick = game.tick }
  state.request_id = id
  state.request_tick = game.tick
  state.requests = (state.requests or 0) + 1
  state.phase = "waiting"
end

-- The answer to THIS walker's request, if it has arrived (results are kept by
-- request id, so walkers never take or overwrite each other's answers).
local function take_path_result(state)
  local r = results()[state.request_id]
  if r then results()[state.request_id] = nil end
  return r
end

-- Forget answers nobody collected (their walker finished or was cancelled).
local function prune_results()
  local now = game.tick
  for id, r in pairs(results()) do
    if now - (r.tick or 0) > RESULT_TTL_TICKS then results()[id] = nil end
  end
  for id, e in pairs(storage.path_requests) do
    if now - (e.tick or 0) > RESULT_TTL_TICKS then storage.path_requests[id] = nil end
  end
end

-- (Re)initialize a walker. `state` must be a plain table stored on the task;
-- all fields are plain data. The first step() issues the pathfinder request.
function M.begin(state, c, target, arrive_within)
  -- Walking tasks take over from driving: hop out first.
  pcall(function()
    if c.driving then c.driving = false end
  end)
  for k in pairs(state) do
    state[k] = nil
  end
  state.target = { x = target.x, y = target.y }
  state.arrive_within = math.max(tonumber(arrive_within) or 1.0, 0.1)
  state.phase = "request"
  state.retries = 0
  state.requests = 0
  state.repathed = false
  state.deadline = nil -- set when the character starts moving (waiting for a path doesn't count)
end

-- Advance the walker one tick. Returns nil while moving, "arrived" once within
-- arrive_within of the target, or {failed = "reason"} when it gives up.
local function fail(state, c, reason)
  if state.request_id then storage.path_requests[state.request_id] = nil end
  c.walking_state = { walking = false }
  return { failed = reason }
end

local function near_blocked_goal(state, c, remaining)
  if remaining > 3 then return false end
  local blocked = false
  pcall(function() blocked = not c.surface.can_place_entity({ name = "character", position = state.target }) end)
  return blocked
end

-- No usable path: a short hop may still be walked straight (the goal itself
-- may be blocked, e.g. a rock); a long one fails with the reason.
local function no_path(state, c, why)
  local d = math.sqrt(dist_sq(c.position, state.target))
  if d <= STRAIGHT_MAX_DIST then
    state.phase = "straight"
    return nil
  end
  return fail(state, c, string.format("%s — (%.1f, %.1f) is %.0f tiles away; water, cliffs or buildings may block "
    .. "every way (an island?). Try a goal on this side, or walk in shorter legs", why, state.target.x, state.target.y, d))
end

function M.step(state, c, task_id)
  local pos = c.position
  if game.tick % 3600 == 0 then prune_results() end

  if dist_sq(pos, state.target) <= state.arrive_within * state.arrive_within then
    c.walking_state = { walking = false }
    return "arrived"
  end
  if state.deadline and game.tick > state.deadline then
    local remaining = math.sqrt(dist_sq(pos, state.target))
    state.deadline = nil
    if near_blocked_goal(state, c, remaining) then
      state.blocked_goal = true
      c.walking_state = { walking = false }
      return "arrived"
    end
    return fail(state, c, string.format("gave up after walking %.0f s, at (%.1f, %.1f), still %.1f tiles from the "
      .. "target — the way there is blocked or much longer than expected",
      (game.tick - (state.moving_since or game.tick)) / 60, pos.x, pos.y, remaining))
  end

  if state.phase == "request" then
    request_path(state, c, task_id)
  end

  if state.phase == "waiting" then
    local result = take_path_result(state)
    if result then
      if result.try_again_later then
        state.retries = state.retries + 1
        if state.retries > MAX_RETRIES then
          local r = no_path(state, c, "the pathfinder stayed busy")
          if r then return r end
        else
          state.phase = "retry_wait"
          state.retry_at = game.tick + RETRY_DELAY_TICKS
        end
      elseif not result.path or #result.path == 0 then
        local r = no_path(state, c, "the pathfinder found no path")
        if r then return r end
      else
        state.path = result.path
        state.waypoint = 1
        state.phase = "following"
        state.best, state.best_tick = nil, nil
      end
    elseif game.tick - state.request_tick > WATCHDOG_TICKS then
      if state.requests < MAX_REQUESTS then
        log(string.format("[factorio-mcp] path request %s got no answer in %d s; asking again",
          tostring(state.request_id), WATCHDOG_TICKS / 60))
        request_path(state, c, task_id)
      else
        local r = no_path(state, c, "the pathfinder didn't answer")
        if r then return r end
      end
    end
    if state.phase == "waiting" then
      c.walking_state = { walking = false }
      return nil
    end
  end

  if state.phase == "retry_wait" then
    if game.tick >= state.retry_at then
      request_path(state, c, task_id)
    end
    c.walking_state = { walking = false }
    return nil
  end

  -- following/straight: a deadline for the walk, from the distance left
  if not state.deadline then
    local d0 = math.sqrt(dist_sq(pos, state.target))
    state.moving_since = game.tick
    state.deadline = game.tick + math.floor(DEADLINE_FACTOR * d0 / SPEED_TILES_PER_TICK) + DEADLINE_SLACK_TICKS
  end

  -- following/straight: pick this tick's goal
  local goal
  if state.phase == "following" then
    local path = state.path
    while state.waypoint <= #path and dist_sq(pos, path[state.waypoint]) <= WAYPOINT_RADIUS_SQ do
      state.waypoint = state.waypoint + 1
      state.best, state.best_tick = nil, nil -- a new waypoint: progress starts over
    end
    if state.waypoint > #path then
      state.phase = "straight" -- path spent; close the last stretch directly
      goal = state.target
      state.best, state.best_tick = nil, nil
    else
      goal = path[state.waypoint]
    end
  else
    goal = state.target
  end

  -- Progress towards the current goal (waypoint or target). Sliding along an
  -- obstacle keeps moving but gets no closer; standing still is caught sooner.
  local d = math.sqrt(dist_sq(pos, goal))
  if not state.best or d < state.best - PROGRESS_MIN then
    state.best, state.best_tick = d, game.tick
  end
  local stuck_still = false
  if not state.last_check_tick then
    state.last_check_tick = game.tick
    state.last_pos = { x = pos.x, y = pos.y }
  elseif game.tick - state.last_check_tick >= STUCK_CHECK_TICKS then
    stuck_still = dist_sq(pos, state.last_pos) < STUCK_EPSILON_SQ
    state.last_check_tick = game.tick
    state.last_pos = { x = pos.x, y = pos.y }
  end
  local off_course = d > state.best + OFF_COURSE_TILES
  local no_progress = off_course or game.tick - state.best_tick >= NO_PROGRESS_TICKS
  if stuck_still or no_progress then
    local remaining = math.sqrt(dist_sq(pos, state.target))
    -- The goal itself may be an obstacle (a rock, a building): standing
    -- right next to it is as close as anyone can get.
    if near_blocked_goal(state, c, remaining) then
      state.blocked_goal = true
      c.walking_state = { walking = false }
      return "arrived"
    end
    if not state.repathed then
      state.repathed = true
      state.no_cache = true
      state.path = nil
      state.deadline = nil
      state.best, state.best_tick = nil, nil
      state.last_check_tick, state.last_pos = nil, nil
      state.requests = 0
      request_path(state, c, task_id)
      c.walking_state = { walking = false }
      return nil
    end
    return fail(state, c, string.format(
      "got stuck at (%.1f, %.1f), still %.1f tiles from the target (%s) — water, cliffs or buildings may be in the way",
      pos.x, pos.y, remaining, stuck_still and "not moving" or "moving but getting no closer"))
  end

  -- walking_state only lasts one tick, so it must be re-set every tick
  c.walking_state = { walking = true, direction = direction_toward(pos, goal) }
  return nil
end

-- Raise the engine pathfinder's per-tick budget (mod setting, 1 = vanilla):
-- by default it expands 1000 nodes per tick for everyone together, so several
-- agents asking for long paths at once queue for seconds. Called on init,
-- configuration changes and when the setting changes.
function M.apply_pathfinder_budget()
  local m = 4
  pcall(function() m = settings.global["factorio-mcp-pathfinder-budget"].value end)
  pcall(function()
    local pf = game.map_settings.path_finder
    pf.max_steps_worked_per_tick = 1000 * m
    pf.max_work_done_per_tick = 8000 * m
  end)
end

-- Wired in control.lua to defines.events.on_script_path_request_finished.
function M.on_path_finished(event)
  local entry = storage.path_requests[event.id]
  if not entry then return end -- not ours, or the walker moved on
  storage.path_requests[event.id] = nil
  local waypoints
  if event.path then
    waypoints = {}
    for i, wp in ipairs(event.path) do
      waypoints[i] = { x = wp.position.x, y = wp.position.y }
    end
  end
  results()[event.id] = { path = waypoints, try_again_later = event.try_again_later or false, tick = game.tick }
end

-- walk_to task runner
function M.start(task)
  local c = companion.require_companion()
  local t = task.target
  if type(t) ~= "table" or type(t.x) ~= "number" or type(t.y) ~= "number" then
    error("walk_to requires target = {x, y}")
  end
  vision.check_walk_goal(c, t)
  task.arrive_within = tonumber(task.arrive_within) or 1.0
  task._walk = {}
  M.begin(task._walk, c, t, task.arrive_within)
end

function M.tick(task)
  local c = companion.get()
  if not c then
    return { status = "failed", detail = "the companion character is gone" }
  end
  local r = M.step(task._walk, c, task.id)
  if r == "arrived" then
    if task._walk.blocked_goal then
      return { status = "done", detail = string.format(
        "arrived at (%.1f, %.1f), next to the goal — (%.1f, %.1f) itself is blocked (a rock, building or water)",
        c.position.x, c.position.y, task.target.x, task.target.y) }
    end
    return { status = "done", detail = string.format("arrived at (%.1f, %.1f)", c.position.x, c.position.y) }
  elseif type(r) == "table" then
    return { status = "failed", detail = r.failed }
  end
  return nil
end

return M
