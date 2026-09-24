-- pick_up: collect items lying on the ground — a destroyed chest's spill, a
-- destroyed belt's cargo, a dropped stack — within a radius of a point,
-- walking over them the way a player collects loot. Mod characters do NOT
-- collect by walking past (the engine's walk-over pickup belongs to GUI
-- players; dense zigzag passes over a scatter took nothing), so this sweeps
-- explicitly: every tick takes the ground items within reach while the
-- character walks to the nearest remaining one. (extract_items at a point
-- picks up the 0.7 tiles around that exact point instead; corpses are
-- emptied with extract_items too.)
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")
local vision = require("scripts.vision")

local M = {}

local DEFAULT_RADIUS = 5
local MAX_RADIUS = 25
local MAX_ITEMS = 500

local function dist_sq(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

function M.start(task)
  local c = companion.require_companion()
  local t = task.target
  if t == nil then
    t = { x = c.position.x, y = c.position.y } -- where I stand
  end
  if type(t) ~= "table" or type(t.x) ~= "number" or type(t.y) ~= "number" then
    error("pick_up takes target = {x, y} (or nothing, for where I stand)")
  end
  local r = tonumber(task.radius) or DEFAULT_RADIUS
  if r < 0.5 or r > MAX_RADIUS then
    error(string.format("pick_up radius must be between 0.5 and %d tiles", MAX_RADIUS))
  end
  task._center = { x = t.x, y = t.y }
  task._radius = r
  task._got = {}
end

local function summary(task)
  local parts, total = {}, 0
  for name, n in pairs(task._got) do
    parts[#parts + 1] = string.format("%d %s", n, name)
    total = total + n
  end
  table.sort(parts)
  return total, string.format("picked up %s from the ground within %g tiles of (%.1f, %.1f)",
    #parts > 0 and table.concat(parts, ", ") or "nothing", task._radius, task._center.x, task._center.y)
end

-- Ground items still in the sweep area, on known ground, nearest first.
local function remaining(task, c)
  local found = {}
  for _, e in ipairs(c.surface.find_entities_filtered({
    position = task._center, radius = task._radius, type = "item-entity",
  })) do
    local st = e.valid and e.stack
    if st and st.valid_for_read and vision.is_known(c.surface, c.force, e.position) then
      found[#found + 1] = e
    end
  end
  table.sort(found, function(a, b) return dist_sq(a.position, c.position) < dist_sq(b.position, c.position) end)
  while #found > MAX_ITEMS do table.remove(found) end
  return found
end

function M.tick(task)
  local c = companion.get()
  if not c then
    return { status = "failed", detail = "the companion character is gone" }
  end
  local main = c.get_main_inventory()
  if not main then
    return { status = "failed", detail = "I have no inventory to carry what I pick up" }
  end

  -- Take everything within reach — the walk over it is the whole cost, like
  -- a player's F. Overflow stays on the ground with its count reduced.
  -- Known ground only, same as the sweep list: the two paths must agree.
  for _, e in ipairs(c.surface.find_entities_filtered({
    position = c.position, radius = c.reach_distance, type = "item-entity",
  })) do
    local st = e.valid and e.stack
    if st and st.valid_for_read and vision.is_known(c.surface, c.force, e.position) then
      local name, count = st.name, st.count
      local put = main.insert({ name = name, count = count, quality = st.quality })
      if put > 0 then
        task._got[name] = (task._got[name] or 0) + put
      end
      if put >= count then
        e.destroy()
      elseif put > 0 then
        st.count = count - put
      end
    end
  end

  local left = remaining(task, c)
  local total, text = summary(task)
  if #left == 0 then
    if total == 0 then
      return { status = "done", detail = string.format(
        "no ground items on known ground within %g tiles of (%.1f, %.1f)",
        task._radius, task._center.x, task._center.y) }
    end
    return { status = "done", detail = text }
  end
  if main.count_empty_stacks() == 0 then
    return {
      status = "failed",
      detail = text .. string.format(" — but my inventory is full and %d item stack%s remain(s); "
        .. "make room and run it again", #left, #left == 1 and "" or "s"),
    }
  end

  -- Walk to the nearest one; the sweep above collects as the character
  -- passes. The target follows the nearest, so a cleared pile advances on
  -- its own.
  local reached = approach.ensure(task, c, left[1].position, c.reach_distance)
  if type(reached) == "table" then return reached end
  return nil -- still walking
end

return M
