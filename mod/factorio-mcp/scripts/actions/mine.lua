-- mine: two forms (see docs/PROTOCOL.md).
--   {target={x,y}}            one mining op on the nearest minable within 2 tiles
--   {resource=name, count=n}  composite: auto-find within 80 tiles (explored chunks only), walk, mine,
--                             hop to the next entity when one is exhausted
-- The engine mines (selected entity + mining_state, like a player), so the
-- character animates and timing/statistics are vanilla; see run_mining_op.
-- Success is measured by inventory delta.
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")
local vision = require("scripts.vision")
local stats = require("scripts.stats")

local M = {}

local TARGET_SEARCH_RADIUS = 2.0
local COMPOSITE_SEARCH_RADIUS = 200
local MAX_OPS = 200
local MINABLE_TYPES = { "resource", "tree", "simple-entity" }

local function dist_sq(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

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

local function op_ticks(c, e)
  return hand_mining_ticks(c, e.prototype.mineable_properties.mining_time or 1)
end

local function product_names(e)
  local names = {}
  for _, p in ipairs(e.prototype.mineable_properties.products or {}) do
    if p.type == "item" then names[#names + 1] = p.name end
  end
  return names
end

-- One mining op on task._entity. Returns nil while mining, or
-- {gained_total=, exhausted=, full=} once the op is over.
--
-- The engine does the mining: the character selects the entity and gets
-- mining_state set, exactly like a player holding the mine button. That gives
-- the mining animation, vanilla timing and the force's production statistics.
-- An op is over when one of the entity's products arrives in the inventory (or
-- the entity is gone). If the engine would select something else at that spot
-- (a drill standing on the ore) or never makes progress, the op falls back to a
-- script timer of the same vanilla length plus LuaEntity.mine().
local function script_op(task, c, m)
  local e = task._entity
  if not (e and e.valid) then
    m.remaining = nil
    return { gained_total = 0, exhausted = true, full = false }
  end
  if not m.remaining then m.remaining = op_ticks(c, e) end
  m.remaining = m.remaining - 1
  if m.remaining > 0 then return nil end
  m.remaining = nil
  local inv = c.get_main_inventory()
  local before_total = inv.get_item_count()
  local before = {}
  for _, name in ipairs(m.op_products) do before[name] = inv.get_item_count(name) end
  local exhausted = e.mine({ inventory = inv, raise_destroyed = true })
  local gained_total = inv.get_item_count() - before_total
  for _, name in ipairs(m.op_products) do
    local g = inv.get_item_count(name) - before[name]
    if g > 0 then
      stats.record_produced(c, name, g) -- script mining isn't in the statistics otherwise
      m.gained[name] = (m.gained[name] or 0) + g
    end
  end
  return { gained_total = gained_total, exhausted = exhausted or not e.valid, full = gained_total <= 0 }
end

local function run_mining_op(task, c, m)
  local e = task._entity
  local inv = c.get_main_inventory()
  if not m.watch then
    m.op_products = product_names(e)
    local before = {}
    for _, name in ipairs(m.op_products) do before[name] = inv.get_item_count(name) end
    m.watch = { before = before, total = inv.get_item_count(), started = game.tick,
                limit = op_ticks(c, e) * 2 + 60, script = false }
  end
  local w = m.watch

  if w.script then
    local r = script_op(task, c, m)
    if r then m.watch = nil end
    return r
  end

  local got = false
  for _, name in ipairs(m.op_products) do
    if inv.get_item_count(name) > w.before[name] then got = true end
  end
  if got or not e.valid then
    for _, name in ipairs(m.op_products) do
      local g = inv.get_item_count(name) - w.before[name]
      if g > 0 then m.gained[name] = (m.gained[name] or 0) + g end
    end
    local gained_total = inv.get_item_count() - w.total
    m.watch = nil
    return { gained_total = gained_total, exhausted = not e.valid, full = false }
  end

  local fits = #m.op_products == 0
  for _, name in ipairs(m.op_products) do
    if inv.can_insert({ name = name, count = 1 }) then fits = true end
  end
  if not fits then
    c.mining_state = { mining = false }
    m.watch = nil
    return { gained_total = 0, exhausted = false, full = true }
  end

  local selected = false
  pcall(function()
    c.update_selected_entity(e.position)
    selected = c.selected == e
  end)
  if not selected or game.tick - w.started > w.limit then
    -- the engine can't be pointed at exactly this entity, or isn't mining it
    c.mining_state = { mining = false }
    w.script = true
    m.remaining = nil
    return nil
  end
  c.mining_state = { mining = true, position = e.position }
  return nil
end

local function gained_list(m)
  local parts = {}
  for name, n in pairs(m.gained) do
    parts[#parts + 1] = string.format("+%d %s", n, name)
  end
  table.sort(parts)
  return table.concat(parts, ", ")
end

-- ---------------------------------------------------------------- single

local function start_single(task, c)
  local target = task.target
  if type(target.x) ~= "number" or type(target.y) ~= "number" then
    error("mine requires target = {x, y}")
  end

  vision.require_known(c.surface, c.force, target, "what is there")
  local candidates = c.surface.find_entities_filtered({
    position = target,
    radius = TARGET_SEARCH_RADIUS,
    type = MINABLE_TYPES,
  })
  local best, best_d
  for _, e in ipairs(candidates) do
    if e.valid and e.prototype.mineable_properties.minable then
      local d = dist_sq(e.position, target)
      if not best or d < best_d then
        best, best_d = e, d
      end
    end
  end
  if not best then
    local building = c.surface.find_entities_filtered({ position = target, radius = TARGET_SEARCH_RADIUS,
      force = c.force, limit = 1 })[1]
    if building and building.valid and building ~= c then
      error(string.format("the %s at (%.1f, %.1f) is a building — use deconstruct to take it down",
        building.name, building.position.x, building.position.y))
    end
    error(string.format(
      "nothing minable within %.0f tiles of (%.1f, %.1f) — I can only mine ore, trees and rocks",
      TARGET_SEARCH_RADIUS, target.x, target.y))
  end

  task._entity = best
  task._entity_name = best.name
  task._mine = { gained = {}, ops = 0 }
  -- with a count, keep mining the same spot (an ore tile) that many times
  task.count = math.max(1, math.min(math.floor(tonumber(task.count) or 1), MAX_OPS))
end

local function tick_single(task, c)
  local e = task._entity
  local result
  if not (e and e.valid) then
    -- the engine removes a rock or tree when it finishes mining it
    if not task._mine.watch then
      return { status = "failed", detail = "the target was mined or destroyed by someone else" }
    end
    result = run_mining_op(task, c, task._mine)
  else
    local reached = approach.ensure(task, c, e.position, c.resource_reach_distance)
    if type(reached) == "table" then return reached end
    if reached ~= "ok" then return nil end
    result = run_mining_op(task, c, task._mine)
  end
  if not result then return nil end
  if result.full then
    if task._mine.ops > 0 then
      return { status = "done", detail = string.format("mined %s %d times (+%s) — stopped early, my inventory is full",
        task._entity_name, task._mine.ops, gained_list(task._mine)) }
    end
    return {
      status = "failed",
      detail = string.format("could not mine %s — inventory full?", task._entity_name),
    }
  end
  task._mine.ops = task._mine.ops + 1
  if task._mine.ops < task.count and not result.exhausted and task._entity and task._entity.valid then
    return nil -- next operation on the same spot
  end
  if task.count > 1 then
    return { status = "done", detail = string.format("mined %s %d time%s (%s)%s", task._entity_name, task._mine.ops,
      task._mine.ops == 1 and "" or "s", gained_list(task._mine),
      result.exhausted and " — that spot is used up now" or "") }
  end
  return {
    status = "done",
    detail = string.format("mined %s (+%d items, carrying %d total)%s",
      task._entity_name, result.gained_total, c.get_main_inventory().get_item_count(),
      result.exhausted and " — that spot is used up now" or ""),
  }
end

-- ------------------------------------------------------------- composite

local function find_nearest_match(c, matcher)
  local filter = { position = c.position, radius = COMPOSITE_SEARCH_RADIUS }
  if matcher.name then
    filter.name = matcher.name
  else
    filter.type = matcher.type
  end
  local candidates = vision.filter_known(c.surface.find_entities_filtered(filter), c.surface, c.force)
  local best, best_d
  for _, e in ipairs(candidates) do
    if e.valid and e.prototype.mineable_properties.minable then
      local d = dist_sq(e.position, c.position)
      if not best or d < best_d then
        best, best_d = e, d
      end
    end
  end
  return best
end

local function start_composite(task, c)
  local resource = task.resource
  local matcher
  if resource == "tree" then
    matcher = { type = "tree" }
  elseif resource == "rock" then
    matcher = { type = "simple-entity" }
  else
    local proto = prototypes.entity[resource]
    if not proto then
      error(string.format(
        "no entity called '%s' — use a resource name like iron-ore, or \"tree\"/\"rock\"", resource))
    end
    if not proto.mineable_properties.minable then
      error(resource .. " can't be mined by hand")
    end
    matcher = { name = resource }
  end

  local count = math.floor(tonumber(task.count) or 1)
  if count < 1 then count = 1 end
  if count > MAX_OPS then count = MAX_OPS end
  task.count = count
  task._mine = { matcher = matcher, ops = 0, gained = {} }
end

local function composite_summary(task, m)
  local items = gained_list(m)
  return string.format("mined %s %d time%s%s",
    task.resource, m.ops, m.ops == 1 and "" or "s",
    items ~= "" and (" (" .. items .. ")") or "")
end

local function tick_composite(task, c)
  local m = task._mine
  local e = task._entity
  if m.watch and not (e and e.valid) then
    -- the op in progress ended with the entity (a rock or tree the engine just mined)
    local done_op = run_mining_op(task, c, m)
    if done_op and done_op.gained_total > 0 then
      m.ops = m.ops + 1
      if m.ops >= task.count then
        return { status = "done", detail = composite_summary(task, m) }
      end
    end
    c.mining_state = { mining = false }
    task._entity = nil
    e = nil
  end
  if not (e and e.valid) then
    e = find_nearest_match(c, m.matcher)
    task._entity = e
    task._approach = nil
    m.remaining = nil
    m.watch = nil
    if not e then
      if m.ops > 0 then
        return {
          status = "done",
          detail = composite_summary(task, m) .. string.format(
            " — no more %s within %d tiles", task.resource, COMPOSITE_SEARCH_RADIUS),
        }
      end
      return {
        status = "failed",
        detail = string.format(
          "no %s within %d tiles of me — explore further or pick another resource",
          task.resource, COMPOSITE_SEARCH_RADIUS),
      }
    end
  end

  local reached = approach.ensure(task, c, e.position, c.resource_reach_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end

  local result = run_mining_op(task, c, m)
  if not result then return nil end
  if result.full then
    if m.ops > 0 then
      return { status = "done", detail = composite_summary(task, m) .. " — stopped early, my inventory is full" }
    end
    return { status = "failed", detail = "could not mine " .. task.resource .. " — my inventory is full" }
  end

  m.ops = m.ops + 1
  if result.exhausted then
    task._entity = nil -- find the next matching entity
  end
  if m.ops >= task.count then
    return { status = "done", detail = composite_summary(task, m) }
  end
  if result.exhausted then
    c.mining_state = { mining = false }
  end
  return nil
end

-- ------------------------------------------------------------------ api

function M.start(task)
  local c = companion.require_companion()
  if type(task.target) == "table" then
    task._mode = "single"
    start_single(task, c)
  elseif type(task.resource) == "string" then
    task._mode = "composite"
    start_composite(task, c)
  else
    error("mine requires target = {x, y} or resource = <name | \"tree\" | \"rock\">")
  end
end

function M.tick(task)
  local c = companion.get()
  if not c then
    return { status = "failed", detail = "the companion character is gone" }
  end
  if task._mode == "composite" then
    return tick_composite(task, c)
  end
  return tick_single(task, c)
end

return M
