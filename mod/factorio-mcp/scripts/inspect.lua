-- inspect: detailed view of ONE entity, located by map position (1.5-tile
-- search, non-characters preferred) or by unit_number (see docs/PROTOCOL.md).
local companion = require("scripts.companion")
local vision = require("scripts.vision")
local approach = require("scripts.actions.approach")
local provenance = require("scripts.provenance")

local M = {}

local SEARCH_RADIUS = 1.5

local function round1(v)
  return math.floor(v * 10 + 0.5) / 10
end

local function round2(v)
  return math.floor(v * 100 + 0.5) / 100
end

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

-- Probe order matters: several defines.inventory values share the same numeric
-- index across entity types (e.g. fuel and chest), so each index is probed
-- once. The fuel slot is relabeled "main" when the entity has no burner.
local INVENTORY_PROBES = {
  { "fuel", "fuel" },
  { "chest", "main" },
  { "furnace_source", "input" },
  { "furnace_result", "output" },
  { "assembling_machine_input", "input" },
  { "assembling_machine_output", "output" },
}

local function collect_inventories(entity)
  local ok_burner, burner = pcall(function() return entity.burner end)
  local has_burner = ok_burner and burner ~= nil

  local result = {}
  local seen = {}
  local found = false
  for _, probe in ipairs(INVENTORY_PROBES) do
    local index = defines.inventory[probe[1]]
    if index and not seen[index] then
      seen[index] = true
      local ok, inv = pcall(entity.get_inventory, index)
      if ok and inv and not inv.is_empty() then
        local label = probe[2]
        if probe[1] == "fuel" and not has_burner then label = "main" end
        local bucket = result[label] or {}
        result[label] = bucket
        for _, item in ipairs(inv.get_contents()) do
          bucket[item.name] = (bucket[item.name] or 0) + item.count
        end
        found = true
      end
    end
  end
  if found then return result end
  return nil
end

-- Items sitting on belt-like entities. Transport line contents come back as
-- an array of {name, count, quality} in 2.x (dict in older styles) — handle both.
local BELT_TYPES = {
  ["transport-belt"] = true,
  ["underground-belt"] = true,
  ["splitter"] = true,
  ["loader"] = true,
  ["loader-1x1"] = true,
  ["linked-belt"] = true,
}

-- Per lane: transport line indices alternate left/right of the direction of
-- travel (1 = left, 2 = right; undergrounds and splitters add 3..8 the same way).
local function collect_belt_lanes(e)
  if not BELT_TYPES[e.type] then return nil end
  local lanes = { left = {}, right = {} }
  local max_index = 2
  pcall(function() max_index = e.get_max_transport_line_index() end)
  for i = 1, max_index do
    local side = (i % 2 == 1) and lanes.left or lanes.right
    local ok, line = pcall(e.get_transport_line, i)
    if ok and line then
      local ok2, contents = pcall(line.get_contents)
      if ok2 and type(contents) == "table" then
        for k, v in pairs(contents) do
          if type(v) == "table" and v.name then
            side[v.name] = (side[v.name] or 0) + (v.count or 0)
          elseif type(v) == "number" then
            side[k] = (side[k] or 0) + v
          end
        end
      end
    end
  end
  return lanes
end

local function collect_belt_contents(e)
  if not BELT_TYPES[e.type] then return nil end
  local totals = {}
  local found = false
  local max_index = 2
  pcall(function() max_index = e.get_max_transport_line_index() end)
  for i = 1, max_index do
    local ok, line = pcall(e.get_transport_line, i)
    if ok and line then
      local ok2, contents = pcall(line.get_contents)
      if ok2 and type(contents) == "table" then
        for k, v in pairs(contents) do
          if type(v) == "table" and v.name then
            totals[v.name] = (totals[v.name] or 0) + (v.count or 0)
            found = true
          elseif type(v) == "number" then
            totals[k] = (totals[k] or 0) + v
            found = true
          end
        end
      end
    end
  end
  if found then return totals end
  return nil
end

-- Fluids in pipes, tanks, boilers, engines, crafting machines with fluid boxes.
local function collect_fluids(e, out)
  -- Integer amounts: x.1 fluid precision isn't useful to an LLM, and rounded
  -- decimals serialize as long floats (87.299999…) in JSON.
  local fluids = nil
  local ok, contents = pcall(e.get_fluid_contents)
  if ok and type(contents) == "table" and next(contents) ~= nil then
    fluids = {}
    for name, amount in pairs(contents) do
      fluids[name] = math.floor(amount + 0.5)
    end
  end
  if not fluids then
    local count = 0
    pcall(function() count = #e.fluidbox end)
    if count > 0 then
      for i = 1, count do
        local ok2, f = pcall(function() return e.fluidbox[i] end)
        if ok2 and f and f.name then
          fluids = fluids or {}
          fluids[f.name] = math.floor((fluids[f.name] or 0) + f.amount + 0.5)
        end
      end
      if not fluids then
        out.no_fluids = true -- has a fluid system, but it's dry
      end
    end
  end
  if fluids then out.fluids = fluids end

  -- Where each fluid connection wants a pipe (map position), and whether
  -- something is connected there — "no input fluid" is often a pipe on the
  -- wrong side.
  pcall(function()
    local fb = e.fluidbox
    if not fb or #fb == 0 then return end
    local conns = {}
    for i = 1, #fb do
      for _, pc in ipairs(fb.get_pipe_connections(i)) do
        if pc.connection_type ~= "linked" and pc.target_position then
          local to
          pcall(function() if pc.target then to = pc.target.owner.name end end)
          conns[#conns + 1] = {
            fluidbox = i,
            flow = pc.flow_direction,
            type = pc.connection_type,
            pipe_at = { x = round1(pc.target_position.x), y = round1(pc.target_position.y) },
            connected_to = to,
          }
        end
      end
    end
    if #conns > 0 then out.fluid_connections = conns end
  end)
end

local function locate(params)
  if params.unit_number ~= nil then
    local n = tonumber(params.unit_number)
    local e = n and game.get_entity_by_unit_number(n)
    if not (e and e.valid) then
      error("no entity with unit_number " .. tostring(params.unit_number)
        .. " — it may have been removed or mined")
    end
    return e
  end

  local pos = params.position
  if type(pos) ~= "table" or tonumber(pos.x) == nil or tonumber(pos.y) == nil then
    error("inspect needs either a position {x, y} or a unit_number")
  end
  local target = { x = tonumber(pos.x), y = tonumber(pos.y) }

  local c = companion.require_companion()
  local surface = c.surface
  vision.require_known(surface, c.force, target, "what is there")

  -- Preference order: buildings/machines > resources > characters. A chest
  -- standing on an ore tile must resolve to the chest, not the ore under it.
  local candidates = vision.filter_perceivable(
    surface.find_entities_filtered({ position = target, radius = SEARCH_RADIUS }), surface, c.force)
  local best, note = approach.pick_entity(candidates, target,
    function(e) return e.type ~= "character" and e.type ~= "resource" end)
  local best_res = approach.pick_entity(candidates, target, function(e) return e.type == "resource" end)
  local best_char = approach.pick_entity(candidates, target, function(e) return e.type == "character" end)
  local entity = best or best_res or best_char
  if not entity then
    error(string.format(
      "nothing to inspect within %.1f tiles of (%.1f, %.1f) — check the position or look_around first",
      SEARCH_RADIUS, target.x, target.y))
  end
  return entity, best and note or nil
end

local function inspect_one(params)
  local e, note = locate(params)

  local out = {
    name = e.name,
    type = e.type,
    unit_number = e.unit_number,
    position = { x = round1(e.position.x), y = round1(e.position.y) },
    direction = e.direction,
  }

  local ok, health = pcall(function() return e.health end)
  if ok and health then out.health = round1(health) end

  -- entity.status can throw or be nil on some types
  local ok_status, status = pcall(function() return e.status end)
  if ok_status and status ~= nil then
    for name, value in pairs(defines.entity_status) do
      if value == status then
        out.status = name
        break
      end
    end
  end

  local ok_recipe, recipe = pcall(e.get_recipe)
  if ok_recipe and recipe then out.recipe = recipe.name end

  local ok_progress, progress = pcall(function() return e.crafting_progress end)
  if ok_progress and type(progress) == "number" then
    out.crafting_progress = round2(progress)
  end

  if note then out.note = note end
  -- Energy buffer in kJ (LuaEntity.energy is joules). Entities that need no
  -- energy (void source, e.g. the offshore pump) report a meaningless number.
  local void = false
  pcall(function() void = e.prototype.void_energy_source_prototype ~= nil end)
  local ok_energy, energy = pcall(function() return (not void) and e.energy or nil end)
  if ok_energy and type(energy) == "number" and energy > 0 then
    out.energy_kj = round1(energy / 1000)
  end
  -- Burner fuel: what's burning and how much energy is left in it.
  pcall(function()
    local b = e.burner
    if b and b.currently_burning then
      local n = b.currently_burning.name
      if type(n) ~= "string" then n = n.name end
      out.burning = n
      out.remaining_burning_kj = round1(b.remaining_burning_fuel / 1000)
    end
  end)

  if e.type == "resource" then out.amount = e.amount end

  -- Mining drills: the resource under the drill and how much is left in its
  -- mining area.
  if e.type == "mining-drill" then
    pcall(function()
      local t = e.mining_target
      if t and t.valid then out.mining_target = t.name end
      local area = e.mining_area
      local total, tiles = 0, 0
      for _, r in ipairs(e.surface.find_entities_filtered({ area = area, type = "resource" })) do
        total = total + (r.amount or 0)
        tiles = tiles + 1
      end
      out.ore_remaining = total
      out.ore_tiles = tiles
    end)
  end

  local inventories = collect_inventories(e)
  if inventories then out.inventories = inventories end

  local belt = collect_belt_contents(e)
  if belt then out.belt_contents = belt end
  local lanes = collect_belt_lanes(e)
  if lanes then
    out.belt_lanes = lanes
    out.belt_direction = e.direction
    -- where items go next, and where they come from (y grows south)
    pcall(function()
      local bn = e.belt_neighbours
      local function xy(t) return { x = round1(t.position.x), y = round1(t.position.y) } end
      local outs = bn.outputs or {}
      if e.type == "underground-belt" and e.belt_to_ground_type == "input" and e.neighbours then outs = { e.neighbours } end
      if outs[1] then out.belt_feeds = xy(outs[1]) end
      local ins = {}
      for _, i in ipairs(bn.inputs or {}) do ins[#ins + 1] = xy(i) end
      out.belt_fed_by = ins
    end)
    if e.type == "underground-belt" then out.underground = require("scripts.belts").underground_note(e) end
  end

  -- who last changed this entity, when a job of this mod did (the fleet is
  -- one force; any agent may rotate or replace a shared building — see
  -- scripts/provenance.lua)
  pcall(function()
    local changed = provenance.note(e)
    if changed then out.last_changed = changed end
  end)

  collect_fluids(e, out)

  return out
end

local MAX_TARGETS = 16

-- Single entity ({position}/{unit_number}) or batched: targets = [{x,y},...]
-- inspects up to MAX_TARGETS entities in ONE call — reading machines one at
-- a time costs the brain a full round of thinking per machine.
function M.inspect(params)
  if type(params.targets) == "table" then
    if #params.targets == 0 then
      error("targets must be a non-empty array of {x, y}")
    end
    if #params.targets > MAX_TARGETS then
      error("inspect takes at most " .. MAX_TARGETS .. " targets per call — split the list")
    end
    local out = {}
    local seen = {}
    for i, t in ipairs(params.targets) do
      local ok, res = pcall(inspect_one, { position = t })
      if ok then
        out[i] = res
        local k = res.unit_number or (res.name .. "@" .. res.position.x .. "," .. res.position.y)
        if seen[k] then
          res.note = (res.note and (res.note .. "; ") or "") .. string.format(
            "target %d resolved to the same %s as target %d — the point (%s, %s) may be meant for a neighbour; "
            .. "use a point inside it", i, res.name, seen[k], tostring(t.x), tostring(t.y))
        else
          seen[k] = i
        end
      else
        out[i] = {
          error = tostring(res):gsub("^.-:%d+:%s*", ""),
          position = { x = tonumber(t.x), y = tonumber(t.y) },
        }
      end
    end
    return { entities = out }
  end
  return inspect_one(params)
end

return M
