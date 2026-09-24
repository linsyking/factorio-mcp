-- Ambient alerts: a one-line digest of the force's warning counts, attached
-- by rpc.lua to every scoped response except heartbeat. Pull-only warnings
-- (map_warnings) need a polling round to be seen; this makes any call — walk,
-- scan, placement — an alert surface, so a starving plant surfaces on the
-- fleet's next call instead of quarters of an hour later.
--
-- Delta-based per character (and per surface): storage.alert_seen holds the
-- counts as of that character's last response, so steady state is silent and
-- a reconnecting agent is told what changed since they actually last called.
-- The counts themselves are shared and cached for CACHE_TTL_TICKS: the fleet
-- calls far more often than the world changes, and deltas only need
-- second-level freshness.
local companion = require("scripts.companion")
local vision = require("scripts.vision")
local analyze = require("scripts.analyze")

local M = {}

local CACHE_TTL_TICKS = 30
local MAX_ITEMS = 5

-- cache[surface.index] = { tick = n, force = name, counts = {status -> n} }
local cache = {}

local function tally(surface, force)
  -- Count-only version of map_warnings' sweep: same classification
  -- (analyze.lua), same fog-of-war filter, no group lists or positions.
  local status_names = analyze.status_names()
  local counts = {}
  for _, e in ipairs(vision.filter_known(surface.find_entities_filtered({ force = force }), surface, force)) do
    if e.valid and e.type ~= "character" then
      local ok, st = pcall(function() return e.status end)
      if ok and st ~= nil then
        local sname = status_names[st] or tostring(st)
        if analyze.PROBLEM_STATUSES[sname] and not analyze.WORKING[sname] then
          counts[sname] = (counts[sname] or 0) + 1
        end
      end
    end
  end
  return counts
end

local function current_counts(surface, force)
  local c = cache[surface.index]
  if not c or c.force ~= force.name or game.tick - c.tick > CACHE_TTL_TICKS then
    c = { tick = game.tick, force = force.name, counts = tally(surface, force) }
    cache[surface.index] = c
  end
  return c.counts
end

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

local function label(sname)
  return (sname:gsub("_", "-"))
end

-- The digest line for this character, or nil when nothing changed (or on any
-- internal error — a digest must never fail the response it rides on).
function M.line(name)
  local ok, line = pcall(function()
    local c = companion.require_companion(name)
    local counts = current_counts(c.surface, c.force)
    local seen = storage.alert_seen
    if not seen then
      seen = {}
      storage.alert_seen = seen
    end
    local mine = seen[name]
    if not mine then
      mine = {}
      seen[name] = mine
    end
    local surf = mine[c.surface.name]
    if not surf then
      -- First response on this surface: take the current counts as the
      -- baseline, silently. A standing problem is the round reads' job; the
      -- digest reports CHANGE since the last call.
      mine[c.surface.name] = copy(counts)
      return nil
    end
    local items = {}
    for sname, n in pairs(counts) do
      local d = n - (surf[sname] or 0)
      if d ~= 0 then items[#items + 1] = { sname = sname, n = n, d = d } end
    end
    for sname, n in pairs(surf) do -- categories that dropped to zero
      if not counts[sname] then items[#items + 1] = { sname = sname, n = 0, d = -n } end
    end
    mine[c.surface.name] = copy(counts)
    if #items == 0 then return nil end
    table.sort(items, function(a, b)
      if math.abs(a.d) ~= math.abs(b.d) then return math.abs(a.d) > math.abs(b.d) end
      return a.sname < b.sname
    end)
    local parts = {}
    for i, it in ipairs(items) do
      if i > MAX_ITEMS then
        parts[#parts + 1] = "+" .. (#items - MAX_ITEMS) .. " more"
        break
      end
      local d = string.format("%+d", it.d)
      if i == 1 then d = d .. " since your last call" end
      parts[#parts + 1] = string.format("%s %d (%s)", label(it.sname), it.n, d)
    end
    return "ALERTS: " .. table.concat(parts, ", ")
  end)
  if ok then return line end
  return nil
end

return M
