-- Offline tests for the ambient ALERTS digest: scripts/alerts.lua (the
-- delta math) and its rpc.lua envelope hook (every scoped response except
-- heartbeat). Uses the REAL analyze classification; entity stubs carry a
-- status number from a fake enum, like warnings_test.
--
-- State tracking: `seen` below is each character's last-seen counts after
-- the check above it ran (the line() call updates the baseline).
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

local S = { normal = 1, working = 2, no_power = 3, no_fuel = 4, output_full = 5,
  waiting_for_source_items = 6, no_minable_resources = 7, no_recipe = 8,
  no_ammo = 9, full_output = 10 }
local status_names = {}
for n, v in pairs(S) do status_names[v] = n end
_G.defines = { entity_status = S }
_G.storage = {}
_G.game = { tick = 1000 }

local found = {}
local function make_surface(name, index)
  return { name = name, index = index, find_entities_filtered = function() return found end }
end
local nauvis = make_surface("nauvis", 1)
local vulcanus = make_surface("vulcanus", 2)

local character = { name = "agent", position = { x = 0, y = 0 }, surface = nauvis, force = { name = "player" } }
local builder = { name = "builder", position = { x = 0, y = 0 }, surface = nauvis, force = { name = "player" } }
local volcano_walker = { name = "v", position = { x = 0, y = 0 }, surface = vulcanus, force = { name = "player" } }
local function pick(name)
  if name == "builder" then return builder end
  if name == "v" then return volcano_walker end
  return character
end

package.loaded["scripts.companion"] = {
  require_companion = function(name) return pick(name) end,
  get = function(name) return pick(name) end,
  touch = function() end,
  set_context = function() end,
  context = function() return "agent" end,
}
package.loaded["scripts.vision"] = {
  filter_known = function(entities) return entities end,
}
package.loaded["scripts.perceive"] = {}

local alerts = require("scripts.alerts")

local function ent(status)
  return { valid = true, name = "assembling-machine-1", type = "assembling-machine",
    status = status, position = { x = 0, y = 0 } }
end
local function many(status, n)
  local out = {}
  for _ = 1, n do out[#out + 1] = ent(status) end
  return out
end
local function join(...)
  local out = {}
  for _, list in ipairs({ ... }) do
    for _, e in ipairs(list) do out[#out + 1] = e end
  end
  return out
end
-- an entity whose status read raises (bad metatable): the digest must skip it
local raising = setmetatable({}, { __index = function() error("boom") end })
raising.valid = true
raising.name = "x"
raising.type = "assembling-machine"
raising.position = { x = 0, y = 0 }

-- Counts are cached for 30 ticks, so every world change in a test is followed
-- by a tick advance past the cache TTL.
local function advance() game.tick = game.tick + 31 end

-- ---------------------------------------------------------------- the digest

found = many(S.no_power, 3)
check(alerts.line("agent") == nil, "first response takes the baseline silently")          -- agent: {no_power=3}
check(alerts.line("agent") == nil, "steady state prints nothing")

found = many(S.no_power, 8)
advance()
check(alerts.line("agent") == "ALERTS: no-power 8 (+5 since your last call)",
  "a new problem is reported with its delta")                                            -- agent: {no_power=8}
check(alerts.line("agent") == nil, "unchanged after the alert: silent again")

found = many(S.no_power, 5)
advance()
check(alerts.line("agent") == "ALERTS: no-power 5 (-3 since your last call)",
  "recovery is reported too")                                                            -- agent: {no_power=5}

found = {}
advance()
check(alerts.line("agent") == "ALERTS: no-power 0 (-5 since your last call)",
  "a problem dropping to zero is named")                                                 -- agent: {}

-- the idle class (starved inserters) is NOT a warning icon: excluded
found = join(many(S.waiting_for_source_items, 4), many(S.no_fuel, 2))
advance()
check(alerts.line("builder") == nil, "a second character takes its own baseline")         -- builder: {no_fuel=2}
found = join(many(S.waiting_for_source_items, 4), many(S.no_fuel, 5))
advance()
check(alerts.line("builder") == "ALERTS: no-fuel 5 (+3 since your last call)",
  "waiting_for_source_items (idle class) is not counted as a warning")                   -- builder: {no_fuel=5}
check(alerts.line("agent") == "ALERTS: no-fuel 5 (+5 since your last call)",
  "the force's problems are shared: agent sees builder's world changes against its own baseline") -- agent: {no_fuel=5}

-- ordering: bigger delta first, ties alphabetical
found = join(many(S.no_fuel, 1), many(S.no_power, 3))
advance()
check(alerts.line("builder") == "ALERTS: no-fuel 1 (-4 since your last call), no-power 3 (+3)",
  "bigger delta first, decreases included")                                              -- builder: {no_fuel=1, no_power=3}
found = join(many(S.no_fuel, 6), many(S.no_power, 8))
advance()
check(alerts.line("builder") == "ALERTS: no-fuel 6 (+5 since your last call), no-power 8 (+5)",
  "equal deltas fall back to name order; only the first item says 'since your last call'") -- builder: {no_fuel=6, no_power=8}

-- more than five changed categories: capped with +N more
found = {}
advance()
check(alerts.line("builder") == "ALERTS: no-power 0 (-8 since your last call), no-fuel 0 (-6)",
  "all-clear is itself just deltas")                                                     -- builder: {}
found = join(many(S.full_output, 1), many(S.no_ammo, 1), many(S.no_fuel, 1),
  many(S.no_minable_resources, 1), many(S.no_power, 1), many(S.no_recipe, 1),
  many(S.output_full, 1))
advance()
check(alerts.line("builder") == "ALERTS: full-output 1 (+1 since your last call), no-ammo 1 (+1), no-fuel 1 (+1), "
  .. "no-minable-resources 1 (+1), no-power 1 (+1), +2 more",
  "at most five categories, then +N more")                                               -- builder: 7 categories at 1

-- the counts cache: a world change within the TTL is invisible
found = {}
advance()
check(alerts.line("agent") == "ALERTS: no-fuel 0 (-5 since your last call)",
  "agent re-baselines for the cache test")                                               -- agent: {}
found = many(S.no_power, 4)
check(alerts.line("agent") == nil, "within the cache TTL the old counts still stand")
advance()
check(alerts.line("agent") == "ALERTS: no-power 4 (+4 since your last call)",
  "past the TTL the fresh counts apply")                                                 -- agent: {no_power=4}

-- per-surface baselines
found = {}
advance()
check(alerts.line("v") == nil, "a character on another surface takes that surface's baseline") -- v(vulcanus): {}
check(alerts.line("agent") == "ALERTS: no-power 0 (-4 since your last call)",
  "agent's own baseline still tracks nauvis")                                            -- agent: {}
found = many(S.no_power, 6)
advance()
check(alerts.line("v") == "ALERTS: no-power 6 (+6 since your last call)",
  "each surface is tracked separately")                                                   -- v: {no_power=6}
check(alerts.line("agent") == "ALERTS: no-power 6 (+6 since your last call)",
  "and the agent (same counts, own baseline) sees it too")                               -- agent: {no_power=6}

-- a status read that raises is skipped, not fatal
found = { raising, ent(S.no_power) }
advance()
check(alerts.line("agent") == "ALERTS: no-power 1 (-5 since your last call)",
  "an entity whose status read raises is skipped, the digest survives")                   -- agent: {no_power=1}

-- ------------------------------------------------- the rpc.lua envelope hook

-- Minimal stand-ins for the two helpers dispatch uses (flat, string-only
-- params in; a small recursive encoder out).
local function esc(s)
  return (s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"))
end
local function to_json(v)
  if type(v) == "string" then return '"' .. esc(v) .. '"' end
  if type(v) == "number" then return string.format("%.14g", v) end
  if v == nil then return "null" end
  if type(v) ~= "table" then return tostring(v) end
  local n = 0
  for k in pairs(v) do
    if type(k) ~= "number" then n = -1 break end
    n = n + 1
  end
  if n == #v and n > 0 then
    local p = {}
    for _, x in ipairs(v) do p[#p + 1] = to_json(x) end
    return "[" .. table.concat(p, ",") .. "]"
  end
  local p = {}
  for k, x in pairs(v) do p[#p + 1] = '"' .. esc(tostring(k)) .. '":' .. to_json(x) end
  return "{" .. table.concat(p, ",") .. "}"
end
_G.helpers = {
  table_to_json = to_json,
  json_to_table = function(s)
    local t = {}
    for k, v in s:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do t[k] = v end
    return t
  end,
}
local captured
_G.rcon = { print = function(s) captured = s end }
storage.rpc_outbox = { next_id = 1, by_id = {} }

local rpc = require("scripts.rpc")
rpc.register("walk", function() return { moved = true } end)
rpc.register("boom", function() error("kaput") end)
rpc.register("heartbeat", function() return { tick = game.tick } end) -- mirrors control.lua

-- a clean slate for the envelope tests
storage.alert_seen = nil
found = many(S.no_power, 4)
advance()
rpc.dispatch("walk", '{"companion":"agent","session":"s1"}')
check(captured:find('"ok":true', 1, true) and captured:find('"moved":true', 1, true),
  "dispatch still answers normally")
check(not captured:find('"alerts"', 1, true), "the first response after a wipe is a silent baseline")

found = many(S.no_power, 7)
advance()
rpc.dispatch("walk", '{"companion":"agent","session":"s1"}')
check(captured:find('"alerts":"ALERTS: no-power 7 (+3 since your last call)"', 1, true),
  "a scoped response carries the digest")

-- heartbeat: no digest, and it must not consume the delta either
found = many(S.no_power, 9)
advance()
rpc.dispatch("heartbeat", '{"companion":"agent","session":"s1"}')
check(not captured:find('"alerts"', 1, true), "heartbeat carries no digest (a keepalive the agent never sees)")
check(storage.alert_seen.agent.nauvis.no_power == 7,
  "heartbeat does not touch the last-seen baseline (it must not swallow alerts)")
rpc.dispatch("walk", '{"companion":"agent","session":"s1"}')
check(captured:find('"alerts":"ALERTS: no-power 9 (+2 since your last call)"', 1, true),
  "the next real call sees the full delta despite the heartbeats in between")

-- a failing handler still carries the digest
found = many(S.no_power, 11)
advance()
rpc.dispatch("boom", '{"companion":"agent","session":"s1"}')
check(captured:find('"ok":false', 1, true) and captured:find("kaput", 1, true),
  "the handler error is reported as before")
check(captured:find('"alerts":"ALERTS: no-power 11 (+2 since your last call)"', 1, true),
  "an error response carries the digest too")

-- unscoped methods never carry it
rpc.dispatch("echo", '{"size":0}')
check(not captured:find('"alerts"', 1, true), "unscoped (ping/echo/get_chunk/bind) responses carry no digest")

if failures > 0 then
  print("\n" .. failures .. " FAILURES")
  os.exit(1)
end
print("\nall alerts checks passed")
