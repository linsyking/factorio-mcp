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

-- The back-pressure class: waiting_for_space_in_destination is the expected
-- state while the fleet builds (belts back up by design), so it NEVER
-- triggers the line — alert fatigue would defeat the whole feature — and
-- rides as a trailing summary count when the line fires for real reasons.
-- Not tunable: a threshold on a category that never triggers is a no-op.
local NEVER_TRIGGERS = { waiting_for_space_in_destination = true }

-- The knob (see /alerts-threshold): each category fires at |delta| >= its
-- threshold, default min_delta for all, per-category overrides on top.
local function config()
  local c = storage.alerts_config
  if type(c) ~= "table" then
    c = { min_delta = 1, by_category = {} }
    storage.alerts_config = c
  end
  c.min_delta = c.min_delta or 1
  if type(c.by_category) ~= "table" then c.by_category = {} end
  return c
end

local function threshold(sname)
  local c = config()
  local over = c.by_category[sname]
  if type(over) == "number" then return over end
  return c.min_delta
end

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
      if not NEVER_TRIGGERS[sname] and math.abs(d) >= threshold(sname) then
        items[#items + 1] = { sname = sname, n = n, d = d }
      end
    end
    for sname, n in pairs(surf) do -- categories that dropped to zero
      if not NEVER_TRIGGERS[sname] and not counts[sname] and math.abs(n) >= threshold(sname) then
        items[#items + 1] = { sname = sname, n = 0, d = -n }
      end
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
    -- The back-pressure class rides along as a summary count, never as a trigger.
    local bp = counts["waiting_for_space_in_destination"]
    if bp and bp > 0 then
      parts[#parts + 1] = "waiting-for-space-in-destination " .. bp
    end
    return "ALERTS: " .. table.concat(parts, ", ")
  end)
  if ok then return line end
  return nil
end

-- /alerts-threshold (registered in control.lua): the digest's delta
-- thresholds, tunable at runtime by server admins (RCON or in-game console)
-- so the knob turns without a mod release. Returns the reply text.
--   /alerts-threshold                      show
--   /alerts-threshold 3                    default for every category
--   /alerts-threshold no-power 5           one category
--   /alerts-threshold no-power reset       back to the default
function M.on_command(e)
  local args = {}
  for w in tostring((e and e.parameter) or ""):gmatch("%S+") do args[#args + 1] = w end
  local c = config()
  local usage = "usage: /alerts-threshold [category] <min |delta| 1-1000, or 'reset'> — no arguments shows the current setting"
  local function number(s)
    local n = tonumber(s)
    if not n or n ~= math.floor(n) or n < 1 or n > 1000 then return nil end
    return n
  end
  if #args == 0 then
    local overs = {}
    for sname, n in pairs(c.by_category) do overs[#overs + 1] = label(sname) .. " " .. n end
    table.sort(overs)
    local extra = overs[1] and ("; overrides: " .. table.concat(overs, ", ")) or ""
    return "ALERTS thresholds: every category fires at |delta| >= " .. c.min_delta .. extra
      .. ". waiting-for-space-in-destination never fires (back-pressure, trailing summary only)"
  end
  if #args > 2 then return usage end
  if #args == 1 then
    local n = number(args[1])
    if not n then return usage end
    c.min_delta = n
    return "ALERTS: every category now fires at |delta| >= " .. n
  end
  local sname = args[1]:gsub("%-", "_")
  if not analyze.PROBLEM_STATUSES[sname] then
    local valid = {}
    for k in pairs(analyze.PROBLEM_STATUSES) do valid[#valid + 1] = label(k) end
    table.sort(valid)
    return "unknown category '" .. args[1] .. "' — valid: " .. table.concat(valid, ", ")
  end
  if NEVER_TRIGGERS[sname] then
    return label(sname) .. " never fires (back-pressure, trailing summary only) — thresholds don't apply"
  end
  if args[2] == "reset" or args[2] == "clear" then
    c.by_category[sname] = nil
    return "ALERTS: " .. label(sname) .. " override cleared (back to default " .. c.min_delta .. ")"
  end
  local n = number(args[2])
  if not n then return usage end
  c.by_category[sname] = n
  return "ALERTS: " .. label(sname) .. " now fires at |delta| >= " .. n
end

return M
