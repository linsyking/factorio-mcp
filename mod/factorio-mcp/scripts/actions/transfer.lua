-- Inventory transfer actions: insert (companion → entity) and extract
-- (entity → companion). Both approach within reach_distance first and report
-- per-item results including shortfalls.
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")
local items = require("scripts.items")

local M = {}

local function gone()
  return { status = "failed", detail = "the companion character is gone" }
end

local function validate_target(task, action)
  local t = task.target
  if type(t) ~= "table" or type(t.x) ~= "number" or type(t.y) ~= "number" then
    error(action .. " requires target = {x, y}")
  end
end

-- {"coal":10, "iron-plate@rare":5} → sorted list of {name = key, count}.
-- `name` stays the full key (with @quality) so messages show the quality.
local function validate_items(spec, action)
  if type(spec) ~= "table" then
    error(action .. " requires items = {\"item-name\": count}")
  end
  local list = {}
  for key, count in pairs(spec) do
    if type(key) ~= "string" or type(count) ~= "number" or count < 1 then
      error(action .. " items must map item names to positive counts")
    end
    local name, quality = items.parse(key)
    if not prototypes.item[name] then
      error("no item called '" .. name .. "'")
    end
    if not prototypes.quality[quality] then
      error("no quality called '" .. quality .. "'")
    end
    list[#list + 1] = { name = key, count = math.floor(count) }
  end
  if #list == 0 then
    error(action .. " needs at least one item")
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

local function no_entity(task, action)
  return {
    status = "failed",
    detail = string.format("nothing at (%.1f, %.1f) to %s — check the position with inspect",
      task.target.x, task.target.y, action),
  }
end

-- ----------------------------------------------------------------- insert

M.insert = {}

function M.insert.start(task)
  companion.require_companion()
  validate_target(task, "insert")
  task._items = validate_items(task.items, "insert")
end

function M.insert.tick(task)
  local c = companion.get()
  if not c then return gone() end

  local reached = approach.ensure(task, c, task.target, c.reach_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end

  local e, pick_note = approach.find_entity_near(c, task.target)
  task._pick_note = pick_note
  if not e then return no_entity(task, "insert into") end

  local moved, problems, total = {}, {}, 0
  for _, it in ipairs(task._items) do
    local have = items.count(c, it.name)
    local n = math.min(it.count, have)
    local inserted = 0
    if n > 0 then
      inserted = e.insert(items.spec(it.name, n))
      if inserted > 0 then
        c.remove_item(items.spec(it.name, inserted))
      end
    end
    total = total + inserted
    if inserted >= it.count then
      moved[#moved + 1] = string.format("%d %s", inserted, it.name)
    elseif inserted > 0 then
      local why = inserted < n and ("the " .. e.name .. " wouldn't take more")
        or string.format("I only had %d", have)
      moved[#moved + 1] = string.format("%d of %d %s (%s)", inserted, it.count, it.name, why)
    elseif have == 0 then
      problems[#problems + 1] = "I have no " .. it.name
    else
      problems[#problems + 1] = "the " .. e.name .. " wouldn't accept " .. it.name
    end
  end

  if total == 0 then
    return {
      status = "failed",
      detail = string.format("couldn't insert anything into the %s — %s",
        e.name, table.concat(problems, "; ")),
    }
  end
  local extra = #problems > 0 and ("; " .. table.concat(problems, "; ")) or ""
  return {
    status = "done",
    detail = string.format("inserted %s into the %s%s", table.concat(moved, ", "), e.name, extra),
  }
end

-- ---------------------------------------------------------------- extract

M.extract = {}

function M.extract.start(task)
  companion.require_companion()
  validate_target(task, "extract")
  if task.all then
    task._all = true
  else
    task._items = validate_items(task.items, "extract")
  end
end

-- Move `count` of `name` from an entity/inventory into the companion;
-- overflow that doesn't fit goes straight back. Returns kept, removed.
-- (LuaObjects error on unknown members, so the source kind is explicit.)
local function pull(c, source, is_inventory, key, count)
  local removed
  if is_inventory then
    removed = source.remove(items.spec(key, count))
  else
    removed = source.remove_item(items.spec(key, count))
  end
  if removed == 0 then return 0, 0 end
  local kept = c.insert(items.spec(key, removed))
  if kept < removed then
    source.insert(items.spec(key, removed - kept))
  end
  return kept, removed
end

local function extract_all(task, c, e)
  local inv = e.get_output_inventory() or e.get_inventory(defines.inventory.chest)
  if not inv then
    return {
      status = "failed",
      detail = "the " .. e.name .. " has no output inventory I can empty",
    }
  end
  local sums = items.inventory_map(inv)
  if next(sums) == nil then
    return { status = "failed", detail = "the " .. e.name .. " is empty — nothing to take" }
  end

  local taken, total = {}, 0
  for name, count in pairs(sums) do
    local kept = pull(c, inv, true, name, count)
    if kept > 0 then
      taken[#taken + 1] = string.format("%d %s", kept, name)
      total = total + kept
    end
  end
  if total == 0 then
    return { status = "failed", detail = "couldn't take anything from the " .. e.name .. " — my inventory is full" }
  end
  table.sort(taken)
  return {
    status = "done",
    detail = string.format("took %s from the %s", table.concat(taken, ", "), e.name),
  }
end

local function extract_items(task, c, e)
  local taken, problems, total = {}, {}, 0
  for _, it in ipairs(task._items) do
    local kept, removed = pull(c, e, false, it.name, it.count)
    total = total + kept
    if kept >= it.count then
      taken[#taken + 1] = string.format("%d %s", kept, it.name)
    elseif kept > 0 then
      local why = kept < removed and "my inventory is full" or "that's all it had"
      taken[#taken + 1] = string.format("%d of %d %s (%s)", kept, it.count, it.name, why)
    else
      problems[#problems + 1] = "it has no " .. it.name
    end
  end
  if total == 0 then
    return {
      status = "failed",
      detail = string.format("couldn't take anything from the %s — %s", e.name, table.concat(problems, "; ")),
    }
  end
  local extra = #problems > 0 and ("; " .. table.concat(problems, "; ")) or ""
  return {
    status = "done",
    detail = string.format("took %s from the %s%s", table.concat(taken, ", "), e.name, extra),
  }
end

function M.extract.tick(task)
  local c = companion.get()
  if not c then return gone() end

  local reached = approach.ensure(task, c, task.target, c.reach_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end

  local e, pick_note = approach.find_entity_near(c, task.target)
  task._pick_note = pick_note
  if not e then return no_entity(task, "extract from") end

  if task._all then
    return extract_all(task, c, e)
  end
  return extract_items(task, c, e)
end

return M
