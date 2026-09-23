-- Shared "walk within reach first" phase for every action task with a map
-- target (see docs/PROTOCOL.md "Tasks"). Sub-state lives under task._approach.
local walk = require("scripts.actions.walk")
local vision = require("scripts.vision")
local placement = require("scripts.placement")

local M = {}

local function dist_sq(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

-- Call every tick before acting on target_pos. Returns "ok" once within
-- `reach` tiles, nil while still walking, or {status="failed", detail=...}.
function M.ensure(task, c, target_pos, reach)
  if dist_sq(c.position, target_pos) <= reach * reach then
    if task._approach then
      task._approach = nil
      c.walking_state = { walking = false }
    end
    return "ok"
  end

  local a = task._approach
  if not a or a.target.x ~= target_pos.x or a.target.y ~= target_pos.y then
    -- Same rule as walk_to: no marching into far unexplored territory.
    local ok, err = pcall(vision.check_walk_goal, c, target_pos)
    if not ok then return { status = "failed", detail = (tostring(err):gsub("^__[%w%-_]+__/[%w%-_/%.]+:%d+: ", "")) } end
    a = { target = { x = target_pos.x, y = target_pos.y }, walk = {} }
    task._approach = a
    walk.begin(a.walk, c, a.target, math.max(reach - 0.5, 0.5))
  end

  local r = walk.step(a.walk, c, task.id)
  if r == "arrived" then
    task._approach = nil
    return "ok"
  elseif type(r) == "table" then
    task._approach = nil
    return { status = "failed", detail = "couldn't get in range: " .. r.failed }
  end
  return nil
end

-- Step out of `area` (a footprint about to be built on) when the character
-- stands inside it, instead of failing the placement. Returns "ok" when
-- clear, nil while walking, or {status="failed", detail=...}.
function M.step_aside(task, c, area)
  if not placement.character_inside(c, area) then
    if task._aside then
      task._aside = nil
      c.walking_state = { walking = false }
    end
    return "ok"
  end
  local s = task._aside
  if not s then
    local cx, cy = (area[1][1] + area[2][1]) / 2, (area[1][2] + area[2][2]) / 2
    local candidates = {
      { cx, area[2][2] + 0.7 }, { cx, area[1][2] - 0.7 }, { area[2][1] + 0.7, cy }, { area[1][1] - 0.7, cy },
    }
    -- prefer the side the character is closest to
    local p = c.position
    table.sort(candidates, function(a, b)
      return (a[1] - p.x) ^ 2 + (a[2] - p.y) ^ 2 < (b[1] - p.x) ^ 2 + (b[2] - p.y) ^ 2
    end)
    local spot
    for _, cand in ipairs(candidates) do
      local free = c.surface.find_non_colliding_position("character", { x = cand[1], y = cand[2] }, 2, 0.25)
      if free and not placement.character_inside({ position = free }, area) then
        spot = free
        break
      end
    end
    if not spot then
      return { status = "failed", detail = "I'm standing in the footprint and found no free spot next to it to step to" }
    end
    s = { walk = {}, tries = 0 }
    task._aside = s
    walk.begin(s.walk, c, spot, 0.2)
  end
  local r = walk.step(s.walk, c, task.id)
  if r == "arrived" then
    task._aside = nil
    return placement.character_inside(c, area) and { status = "failed",
      detail = "I'm standing in the footprint and couldn't step out of it" } or "ok"
  elseif type(r) == "table" then
    task._aside = nil
    return { status = "failed", detail = "couldn't step out of the footprint: " .. r.failed }
  end
  return nil
end

-- Nearest operable entity around a target position (for insert/extract/
-- rotate/set_recipe). Skips the companion itself and things those actions
-- never apply to.
local SKIP_TYPES = { character = true, resource = true, tree = true, ["item-entity"] = true }

function M.find_entity_near(c, pos, radius)
  local candidates = c.surface.find_entities_filtered({ position = pos, radius = radius or 1.5 })
  local best, best_d
  for _, e in ipairs(candidates) do
    if e.valid and e ~= c and not SKIP_TYPES[e.type] then
      local d = dist_sq(e.position, pos)
      if not best or d < best_d then
        best, best_d = e, d
      end
    end
  end
  return best
end

return M
