-- map_warnings: the map screen's warning icons, as one punch list — every
-- machine of the character's force on charted ground whose status is a
-- problem (analyze.lua's classification), grouped by problem with positions.
-- analyze_factory does this for a radius around the character; this sweeps
-- everything the force has charted, the way the map view shows a player.
--
-- Fairness: only entities on KNOWN ground (explored by the force's agent
-- characters or charted by the force) are reported — exactly what the map UI
-- renders. Idle-but-healthy states (an inserter waiting for items) are not
-- warnings and are skipped.
local companion = require("scripts.companion")
local vision = require("scripts.vision")
local analyze = require("scripts.analyze")

local M = {}

local MAX_ENTITIES_PER_GROUP = 60
local MAX_IDLE_ENTITIES = 20

-- Not warning icons (the map shows nothing for these), but the fleet's
-- "starved-but-powered" class: an inserter with nothing to pick up. Reported
-- in its own clearly-labelled section, never merged into the problem groups.
local IDLE_STATUSES = { waiting_for_source_items = true }

local function round1(v)
  return math.floor(v * 10 + 0.5) / 10
end

function M.map_warnings(params)
  local c = companion.require_companion()
  local surface, force = c.surface, c.force

  local status_names = analyze.status_names()

  -- One query for the whole surface, then the fog-of-war filter drops
  -- everything on uncharted ground (the mod must not learn it either).
  local all = surface.find_entities_filtered({ force = force })
  local groups, order = {}, {}
  local idle -- inserters with nothing to pick up: reported separately, last
  local checked = 0
  local function add_to(g, e)
    g.count = g.count + 1
    g.by_name[e.name] = (g.by_name[e.name] or 0) + 1
    g.entities[#g.entities + 1] = {
      name = e.name,
      x = round1(e.position.x),
      y = round1(e.position.y),
      _d = (e.position.x - c.position.x) ^ 2 + (e.position.y - c.position.y) ^ 2,
    }
  end
  for _, e in ipairs(vision.filter_known(all, surface, force)) do
    if e.valid and e.type ~= "character" then
      local ok, st = pcall(function() return e.status end)
      if ok and st ~= nil then
        checked = checked + 1
        local sname = status_names[st] or tostring(st)
        if analyze.PROBLEM_STATUSES[sname] and not analyze.WORKING[sname] then
          local g = groups[sname]
          if not g then
            g = { problem = sname, count = 0, by_name = {}, entities = {} }
            groups[sname] = g
            order[#order + 1] = g
          end
          add_to(g, e)
        elseif IDLE_STATUSES[sname] then
          if not idle then
            idle = { problem = sname, count = 0, by_name = {}, entities = {}, idle = true }
          end
          add_to(idle, e)
        end
      end
    end
  end

  local total = 0
  for _, g in ipairs(order) do
    total = total + g.count
  end
  local function finish(g, cap)
    table.sort(g.entities, function(a, b) return a._d < b._d end)
    if #g.entities > cap then
      g.more = #g.entities - cap
      for i = #g.entities, cap + 1, -1 do g.entities[i] = nil end
    end
    for _, ent in ipairs(g.entities) do ent._d = nil end
  end
  for _, g in ipairs(order) do finish(g, MAX_ENTITIES_PER_GROUP) end
  table.sort(order, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.problem < b.problem
  end)
  if idle then
    finish(idle, MAX_IDLE_ENTITIES)
    order[#order + 1] = idle -- always last, after the warning groups
  end

  return {
    surface = surface.name,
    entities_checked = checked,
    with_problems = total,
    groups = order,
  }
end

return M
