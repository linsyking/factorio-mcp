-- Offline tests for map_warnings: the whole-charted-ground warning sweep.
-- Uses the REAL scripts.analyze classification (exported) and a stubbed
-- vision filter; entity stubs carry a status number from a fake enum.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

local S = { normal = 1, working = 2, no_power = 3, not_plugged_in_electric_network = 4,
  no_fuel = 5, full_output = 6, waiting_for_source_items = 7, no_recipe = 8 }
local status_names = {}
for n, v in pairs(S) do status_names[v] = n end
_G.defines = { entity_status = S }

-- analyze.lua is loaded for real (it only needs these at load time).
package.loaded["scripts.companion"] = { require_companion = function() return {} end }
package.loaded["scripts.vision"] = {}
package.loaded["scripts.perceive"] = {}
local analyze = require("scripts.analyze")
check(analyze.PROBLEM_STATUSES.no_power and not analyze.PROBLEM_STATUSES.waiting_for_source_items,
  "map_warnings: analyze exports the shared problem classification")
local names = analyze.status_names()
check(names[S.no_power] == "no_power", "map_warnings: analyze exports the status name map")

local character = {
  position = { x = 0, y = 0 },
  surface = { name = "nauvis" },
  force = { name = "player" },
}
package.loaded["scripts.companion"] = {
  require_companion = function() return character end,
  get = function() return character end,
}

local found -- what the surface query returns
character.surface.find_entities_filtered = function(filter)
  check(filter.force == character.force, "map_warnings: queries its own force")
  return found
end
-- fog of war: the vision stub drops entities flagged as uncharted
package.loaded["scripts.vision"] = {
  filter_known = function(entities)
    local out = {}
    for _, e in ipairs(entities) do
      if not e.in_fog then out[#out + 1] = e end
    end
    return out
  end,
}

local warnings = require("scripts.warnings")

local function ent(name, type, status, x, y, extra)
  local e = { valid = true, name = name, type = type or "assembling-machine",
    status = status, position = { x = x, y = y } }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end

-- grouping, classification, ordering, positions
found = {
  ent("assembling-machine-1", nil, S.no_power, 10, 0),
  ent("assembling-machine-1", nil, S.no_power, 2, 0),
  ent("burner-inserter", "inserter", S.not_plugged_in_electric_network, 5, 5),
  ent("burner-mining-drill", "mining-drill", S.no_fuel, -3, 0),
  ent("transport-belt", "transport-belt", S.normal, 1, 1),          -- healthy: skipped
  ent("inserter", "inserter", S.waiting_for_source_items, 1, 1),     -- idle, no warning icon: skipped
  ent("agent-7", "character", S.no_power, 0, 0),                     -- characters: skipped
  ent("stone-furnace", nil, S.no_power, 99, 99, { in_fog = true }),  -- uncharted: skipped
  ent("steel-furnace", nil, S.full_output, -1, 4),
}
local r = warnings.map_warnings({})
check(r.with_problems == 5 and r.entities_checked == 7,
  "map_warnings: 5 problem machines of 7 checked; healthy, characters and fog excluded")
check(#r.groups == 5 and r.groups[5].idle == true and r.groups[5].problem == "waiting_for_source_items",
  "map_warnings: idle inserters get their own trailing section, never a problem group")
check(r.groups[1].problem == "no_power" and r.groups[1].count == 2 and r.groups[1].idle == nil,
  "map_warnings: problem groups sorted by count, no_power first")
check(r.groups[1].by_name["assembling-machine-1"] == 2 and #r.groups[1].entities == 2,
  "map_warnings: by_name breakdown and entity list per group")
check(r.groups[1].entities[1].x == 2 and r.groups[1].entities[2].x == 10,
  "map_warnings: entities nearest-first within a group")
local fog_free = true
for _, g in ipairs(r.groups) do
  for _, e in ipairs(g.entities) do
    if e.x == 99 and e.y == 99 then fog_free = false end
  end
end
check(fog_free, "map_warnings: nothing from uncharted ground is reported")

-- a clean factory
found = { ent("transport-belt", "transport-belt", S.normal, 0, 0) }
r = warnings.map_warnings({})
check(r.with_problems == 0 and (r.groups == nil or #r.groups == 0),
  "map_warnings: a healthy factory reports no groups")

-- the per-group cap
found = {}
for i = 1, 65 do
  found[#found + 1] = ent("assembling-machine-1", nil, S.no_recipe, i, 0)
end
for i = 1, 25 do
  found[#found + 1] = ent("inserter", "inserter", S.waiting_for_source_items, -i, 0)
end
r = warnings.map_warnings({})
check(#r.groups[1].entities == 60 and r.groups[1].more == 5 and r.groups[1].count == 65,
  "map_warnings: at most 60 positions per group, the rest counted in more")
check(r.groups[#r.groups].idle == true and #r.groups[#r.groups].entities == 20 and r.groups[#r.groups].more == 5,
  "map_warnings: the idle section caps at 20 positions, the rest counted in more, and stays last")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
