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

-- Belts take items the way a player drops them on (one at a time onto a
-- lane, as long as there is room); LuaEntity.insert refuses belts.
local BELTS = { ["transport-belt"] = true, ["underground-belt"] = true, splitter = true }

-- Slots along one belt tile's lane (0 = its output end): a player dropping
-- items fills the tile; up to 4 per lane, 8 per tile.
local SLOTS = { 0.875, 0.625, 0.375, 0.125 }

local function belt_insert(e, spec)
  local n = 0
  pcall(function()
    local max_i = math.min(e.get_max_transport_line_index(), 2)
    for i = 1, max_i do
      local line = e.get_transport_line(i)
      for _, at in ipairs(SLOTS) do
        if n >= spec.count then break end
        local ok = false
        pcall(function()
          if line.can_insert_at(at) then ok = line.insert_at(at, { name = spec.name, count = 1, quality = spec.quality }) end
        end)
        if ok then n = n + 1 end
      end
      if n >= spec.count then break end
    end
  end)
  return n
end

local function entity_insert(e, spec)
  if BELTS[e.type] then return belt_insert(e, spec) end
  return e.insert(spec)
end
M.entity_insert = entity_insert

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
      inserted = entity_insert(e, items.spec(it.name, n))
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
  -- into the main inventory: the character's own insert would load ammo
  -- straight into the gun's ammo slot
  local main = c.get_main_inventory()
  local kept = (main or c).insert(items.spec(key, removed))
  if kept < removed then
    -- give back what didn't fit (belts refuse LuaEntity.insert: use their lanes)
    if is_inventory then
      source.insert(items.spec(key, removed - kept))
    else
      entity_insert(source, items.spec(key, removed - kept))
    end
  end
  return kept, removed
end

-- Every inventory of the entity except module slots: output, chest, fuel,
-- burnt fuel, input (a player's "take all" empties a furnace's fuel too).
local function all_inventories(e)
  local out = {}
  pcall(function()
    for i = 1, e.get_max_inventory_index() do
      local inv = e.get_inventory(i)
      local nm = ""
      pcall(function() nm = inv and inv.name or "" end)
      if inv and not tostring(nm):find("module") then out[#out + 1] = inv end
    end
  end)
  if #out == 0 then
    local inv = e.get_output_inventory() or e.get_inventory(defines.inventory.chest)
    if inv then out[1] = inv end
  end
  return out
end

local function extract_all(task, c, e)
  local invs = all_inventories(e)
  if #invs == 0 then
    return { status = "failed", detail = "the " .. e.name .. " has no inventory I can empty" }
  end
  local taken_by, total, anything = {}, 0, false
  for _, inv in ipairs(invs) do
    for name, count in pairs(items.inventory_map(inv)) do
      anything = true
      local kept = pull(c, inv, true, name, count)
      if kept > 0 then
        taken_by[name] = (taken_by[name] or 0) + kept
        total = total + kept
      end
    end
  end
  if not anything then
    return { status = "failed", detail = "the " .. e.name .. " is empty — nothing to take" }
  end
  if total == 0 then
    return { status = "failed", detail = "couldn't take anything from the " .. e.name .. " — my inventory is full" }
  end
  local taken = {}
  for name, n in pairs(taken_by) do taken[#taken + 1] = string.format("%d %s", n, name) end
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

  local e, pick_note, inside = approach.find_entity_near(c, task.target)
  -- Items lying on the ground at the point (and no building covering it):
  -- pick them up, like a player pressing F over them.
  if not inside then
    local ground = c.surface.find_entities_filtered({ position = task.target, radius = 0.7, type = "item-entity" })
    if #ground > 0 then
      local want
      if not task._all then
        want = {}
        for _, it in ipairs(task._items) do want[it.name] = true end
      end
      local main = c.get_main_inventory()
      local got, total = {}, 0
      for _, g in ipairs(ground) do
        local st = g.valid and g.stack
        if st and st.valid_for_read and (not want or want[st.name]) then
          local name, count = st.name, st.count
          local put = main.insert({ name = name, count = count, quality = st.quality })
          if put >= count then g.destroy() elseif put > 0 then st.count = count - put end
          if put > 0 then got[name] = (got[name] or 0) + put total = total + put end
        end
      end
      if total > 0 then
        local parts = {}
        for name, n in pairs(got) do parts[#parts + 1] = string.format("%d %s", n, name) end
        table.sort(parts)
        return { status = "done", detail = "picked up " .. table.concat(parts, ", ") .. " from the ground" }
      end
    end
  end
  task._pick_note = pick_note
  if not e then return no_entity(task, "extract from") end

  if task._all then
    return extract_all(task, c, e)
  end
  return extract_items(task, c, e)
end

return M
