-- analyze_factory: one-call diagnosis of everything that's stuck in an area,
-- grouped by (machine, problem) with a sample position and — where we can
-- tell — the missing ingredient. Saves the model a dozen inspect calls.
local companion = require("scripts.companion")
local vision = require("scripts.vision")
local perceive = require("scripts.perceive")

local M = {}

local DEFAULT_RADIUS = 40
local MAX_RADIUS = 150
local MAX_PROBLEM_GROUPS = 15

-- Statuses reported as problems. Everything else that isn't working (idle
-- inserters waiting for items, disabled machines, ...) is still counted, in
-- other_states, so the totals always add up.
local WORKING = { working = true, normal = true, charging = true, discharging = true, fully_charged = true }
local PROBLEM_STATUSES = {
  no_power = true,
  low_power = true,
  no_fuel = true,
  no_ingredients = true,
  no_input_fluid = true,
  no_recipe = true,
  no_research_in_progress = true,
  missing_required_fluid = true,
  no_minable_resources = true,
  output_full = true,
  full_output = true,
  full_burnt_result_output = true,
  not_enough_space_in_output = true,
  waiting_for_space_in_destination = true, -- e.g. a drill whose furnace/belt is full
  no_ammo = true,
  missing_science_packs = true,
  not_plugged_in_electric_network = true,
  recipe_not_researched = true,
  no_filter = true,
  item_ingredient_shortage = true,
  fluid_ingredient_shortage = true,
  low_input_fluid = true,
  networks_disconnected = true,
}

local function round_half(v)
  return math.floor(v * 2 + 0.5) / 2
end

local function dist_sq(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

-- Which ingredients a stalled crafting machine is short of (best effort).
local function missing_ingredients(e)
  local result = nil
  pcall(function()
    local recipe = e.get_recipe()
    if not recipe then return end
    local missing = {}
    local inv = e.get_inventory(defines.inventory.assembling_machine_input)
      or e.get_inventory(defines.inventory.furnace_source)
    for _, ing in ipairs(recipe.ingredients) do
      local have = 0
      if ing.type == "item" then
        have = inv and inv.get_item_count(ing.name) or 0
      else
        pcall(function() have = e.get_fluid_count(ing.name) end)
      end
      if have < (ing.amount or 1) then
        missing[#missing + 1] = ing.name
      end
    end
    if #missing > 0 then
      result = table.concat(missing, ", ")
    end
  end)
  return result
end

function M.analyze_factory(params)
  local radius = math.max(1, math.min(tonumber(params.radius) or DEFAULT_RADIUS, MAX_RADIUS))
  local c = companion.require_companion()
  local origin, surface, force = c.position, c.surface, c.force

  local status_names = {}
  for name, value in pairs(defines.entity_status) do
    status_names[value] = name
  end

  local groups = {}
  local others = {}
  local working, checked = 0, 0
  for _, e in ipairs(vision.filter_known(surface.find_entities_filtered({
    position = origin, radius = radius, force = force,
  }), surface, force)) do
    if e.valid and e.type ~= "character" then
      local ok, st = pcall(function() return e.status end)
      if ok and st ~= nil then
        checked = checked + 1
        local sname = status_names[st] or tostring(st)
        if WORKING[sname] then
          working = working + 1
        elseif not PROBLEM_STATUSES[sname] then
          local okey = e.name .. "|" .. sname
          others[okey] = (others[okey] or 0) + 1
        else
          local key = e.name .. "|" .. sname
          local g = groups[key]
          if not g then
            g = {
              name = e.name,
              problem = sname,
              count = 0,
              _d = math.huge,
              _sample_entity = nil,
            }
            groups[key] = g
          end
          g.count = g.count + 1
          local d = dist_sq(e.position, origin)
          if d < g._d then
            g._d = d
            g.sample = { x = round_half(e.position.x), y = round_half(e.position.y) }
            g._sample_entity = e
          end
        end
      end
    end
  end

  local problems = {}
  for _, g in pairs(groups) do
    problems[#problems + 1] = g
  end
  table.sort(problems, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a._d < b._d
  end)
  while #problems > MAX_PROBLEM_GROUPS do table.remove(problems) end
  for _, g in ipairs(problems) do
    if (g.problem == "no_ingredients" or g.problem == "item_ingredient_shortage"
        or g.problem == "fluid_ingredient_shortage" or g.problem == "no_input_fluid")
      and g._sample_entity and g._sample_entity.valid then
      g.missing = missing_ingredients(g._sample_entity)
    end
    g._sample_entity, g._d = nil, nil
  end

  local problem_count = 0
  for _, g in pairs(groups) do problem_count = problem_count + g.count end
  local other_list, other_count = {}, 0
  for key, n in pairs(others) do
    local name, st = key:match("^(.-)|(.*)$")
    other_list[#other_list + 1] = { name = name, state = st, count = n }
    other_count = other_count + n
  end
  table.sort(other_list, function(a, b) return a.count > b.count end)
  local out = {
    radius = radius,
    machines_checked = checked,
    working = working,
    with_problems = problem_count,
    in_other_states = other_count,
  }
  if #problems > 0 then out.problems = problems end
  if #other_list > 0 then out.other_states = other_list end

  local power = perceive.power_summary(surface, force, origin, radius, nil)
  if power then out.power = power end

  return out
end

return M
