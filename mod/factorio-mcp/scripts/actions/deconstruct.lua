-- deconstruct: mine the force's own buildings back into the character's
-- inventory, taking vanilla hand-mining time. Characters are never targets;
-- trees/rocks/ore go through the plain mine task instead.
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")
local vision = require("scripts.vision")

-- Vanilla hand-mining time: mining_time / (character mining speed x (1 +
-- force bonus + character bonus)). The character prototype's mining_speed is
-- 0.5, so 1 s of mining_time takes 2 s (measured live: 0.496 iron ore/s).
local function hand_mining_ticks(c, mining_time)
  local base = 0.5
  pcall(function() base = c.prototype.mining_speed or 0.5 end)
  local bonus = 1
  pcall(function() bonus = 1 + (c.force.manual_mining_speed_modifier or 0) + (c.character_mining_speed_modifier or 0) end)
  return math.max(1, math.ceil((mining_time or 1) * 60 / (base * bonus)))
end

local M = {}

local AREA_MAX_RADIUS = 10
local AREA_MAX_ENTITIES = 50

local function dist_sq(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

local function is_demolishable(e, c)
  if not e.valid or e == c or e.type == "character" then return false end
  local minable = false
  pcall(function() minable = e.prototype.mineable_properties.minable end)
  return minable
end

function M.start(task)
  local c = companion.require_companion()
  local where = task.target or (task.area and task.area.center)
  if type(where) == "table" and type(where.x) == "number" and type(where.y) == "number" then
    vision.require_known(c.surface, c.force, where, "buildings there")
  end

  -- LuaEntity refs are storable in task state and stay resolvable — unlike
  -- game.get_entity_by_unit_number, which returns nil for most entities.
  local targets = {}
  if task.target and type(task.target.x) == "number" and type(task.target.y) == "number" then
    -- Only a building that covers the point (or the tile a whole-number
    -- point names): demolishing the nearest neighbour of an empty tile
    -- destroyed good belts one after another.
    local candidates = c.surface.find_entities_filtered({ position = task.target, radius = 2, force = c.force })
    local best, note, inside = approach.pick_entity(candidates, task.target, function(e) return is_demolishable(e, c) end)
    if not best then
      error(string.format("no building of ours within 2 tiles of (%.1f, %.1f)",
        task.target.x, task.target.y))
    end
    if not inside then
      error(string.format("nothing of ours at (%.1f, %.1f) — the nearest building is the %s at (%.1f, %.1f); "
        .. "pass its position to take it down", task.target.x, task.target.y, best.name, best.position.x, best.position.y))
    end
    task._pick_note = note
    targets[1] = best
  elseif task.area and task.area.center and type(task.area.center.x) == "number" then
    local radius = math.min(tonumber(task.area.radius) or 5, AREA_MAX_RADIUS)
    local found = {}
    for _, e in ipairs(c.surface.find_entities_filtered({
      position = task.area.center, radius = radius, force = c.force,
    })) do
      if is_demolishable(e, c) then
        found[#found + 1] = { e = e, d = dist_sq(e.position, task.area.center) }
      end
    end
    if #found == 0 then
      error("nothing of ours to demolish there")
    end
    table.sort(found, function(a, b) return a.d < b.d end)
    for i = 1, math.min(#found, AREA_MAX_ENTITIES) do
      targets[i] = found[i].e
    end
  else
    error("deconstruct needs target={x,y} or area={center={x,y}, radius}")
  end

  task._d = { queue = targets, idx = 1, removed = 0, items = 0 }
end

local function summary(d)
  return string.format("demolished %d building%s (+%d items into my inventory)",
    d.removed, d.removed == 1 and "" or "s", d.items)
end

function M.tick(task)
  local c = companion.get()
  if not c then
    return { status = "failed", detail = "the companion character is gone" }
  end
  local d = task._d

  -- Advance to the next still-existing target.
  local e = d.current
  if not (e and e.valid) then
    d.current = nil
    d.remaining = nil
    while d.idx <= #d.queue do
      local candidate = d.queue[d.idx]
      d.idx = d.idx + 1
      if candidate and candidate.valid then
        e = candidate
        d.current = candidate
        break
      end
    end
    if not (e and e.valid) then
      c.mining_state = { mining = false }
      if d.removed == 0 then
        return { status = "failed", detail = "nothing left to demolish — someone beat me to it?" }
      end
      return { status = "done", detail = summary(d) }
    end
  end

  local reached = approach.ensure(task, c, e.position, c.reach_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end

  if not d.remaining then
    local mining_time = 0.5
    pcall(function() mining_time = e.prototype.mineable_properties.mining_time or 0.5 end)
    d.remaining = hand_mining_ticks(c, mining_time)
  end
  c.mining_state = { mining = true, position = e.position }
  d.remaining = d.remaining - 1
  if d.remaining > 0 then return nil end
  d.remaining = nil
  c.mining_state = { mining = false }

  local inv = c.get_main_inventory()
  local before = inv.get_item_count()
  local name = e.name
  local removed = false
  pcall(function() removed = e.mine({ inventory = inv, raise_destroyed = true }) end)
  local gained = inv.get_item_count() - before
  if not removed and e.valid then
    return {
      status = "failed",
      detail = string.format("couldn't remove the %s — my inventory is probably full (%s so far)",
        name, summary(task._d)),
    }
  end
  d.removed = d.removed + 1
  d.items = d.items + gained
  d.current = nil
  return nil
end

return M
