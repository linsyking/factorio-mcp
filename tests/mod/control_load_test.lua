-- Loads control.lua itself — the registration stage that crashed the 0.2.16
-- deploy ("Unknown filter type: force": an event filter preset 2.0 rejects at
-- load time, killing the whole mod and crash-looping the server). The
-- stubbed `script` records every registration; the doctrine check then
-- rejects ANY event filter table in control.lua — internal checks only,
-- because engine-side filter presets are version-brittle.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

_G.storage = {}
_G.game = {
  tick = 0, players = {}, connected_players = {}, forces = {},
  online_players = {},
}
local events_mt = { __index = function(_, k) return "evt:" .. tostring(k) end }
_G.defines = {
  events = setmetatable({}, events_mt),
  alert_type = { turret_out_of_ammo = 1 },
  inventory = { turret_ammo = 1 },
  flow_precision_index = { one_minute = 1 },
  shooting = { not_shooting = 1 },
  entity_status = { normal = 1 },
  direction = { north = 0, east = 4, south = 8, west = 12 },
}
_G.remote = { add_interface = function() end }
_G.commands = { add_command = function() end }

local registered = { events = {}, nth = {}, init = 0, load = 0 }
_G.script = {
  on_init = function() registered.init = registered.init + 1 end,
  on_configuration_changed = function() registered.init = registered.init + 1 end,
  on_load = function() registered.load = registered.load + 1 end,
  on_event = function(ev, _, filters)
    local names = {}
    if type(ev) == "table" then
      for _, e in ipairs(ev) do names[#names + 1] = tostring(e) end
    else
      names[1] = tostring(ev)
    end
    registered.events[#registered.events + 1] = { names = names, filters = filters }
  end,
  on_nth_tick = function(n) registered.nth[n] = true end,
  active_mods = { ["factorio-mcp"] = "test", base = "2.0" },
}

local ok, err = pcall(dofile, here .. "/../../mod/factorio-mcp/control.lua")
check(ok, "control.lua loads clean (no error at registration time)"
  .. (ok and "" or (": " .. tostring(err))))

if ok then
  local damaged, died, both_unfiltered = false, false, true
  for _, r in ipairs(registered.events) do
    for _, n in ipairs(r.names) do
      if n == "evt:on_entity_damaged" then damaged = true end
      if n == "evt:on_entity_died" then died = true end
    end
    if r.filters ~= nil then both_unfiltered = false end
  end
  check(damaged, "control.lua registers on_entity_damaged")
  check(died, "control.lua registers on_entity_died")
  check(both_unfiltered, "no handler is registered with an event filter table (the 0.2.16 crash class)")
  check(registered.nth[30] == true, "the 30-tick combat flush is registered")

  local rpc = require("scripts.rpc")
  check(rpc.handlers["ping"] ~= nil, "ping is registered")
  check(rpc.handlers["map_warnings"] ~= nil, "map_warnings is registered")
  check(rpc.handlers["alerts"] ~= nil and rpc.handlers["battle_report"] ~= nil, "combat RPCs are registered")
  check(rpc.handlers["check_inventory"] ~= nil and rpc.handlers["enqueue"] ~= nil, "core RPCs are registered")
end

-- The doctrine, enforced on the source: engine-side event filters are
-- version-brittle (2.0 dropped the "force" preset 1.1 had). Handlers check
-- their scope internally instead.
local f = io.open(here .. "/../../mod/factorio-mcp/control.lua", "r")
check(f ~= nil, "control.lua is readable for the doctrine scan")
if f then
  local src = f:read("*a")
  f:close()
  check(string.find(src, "filter =", 1, true) == nil,
    "control.lua source contains no 'filter =' table (doctrine: internal checks only)")
end

-- The require doctrine, enforced on the source of every mod file: `require`
-- only works while control.lua is parsed — at runtime (an RPC handler) it
-- raises "Require can't be used outside of control.lua parsing". The 0.2.17
-- bug: the underground-belt notes in build_plan and the underground render
-- in inspect both lazily required scripts.belts from inside a function, so UG
-- placements reported FAILED after actually placing (cancelling the rest of
-- the chain) and inspect_entity could not render undergrounds. A module
-- require must be a load-time top-level assignment (header or the tasks
-- table, indent <= 2) whose result is used as-is.
-- The require doctrine (every module require must be a load-time top-level
-- assignment; a runtime `require` raises "Require can't be used outside of
-- control.lua parsing" and killed UG placements in 0.2.16) is enforced on
-- the same source by tests/test_mod_doctrine.py — lupa has no io.popen, so
-- the file walk lives on the Python side.

os.exit(failures == 0 and 0 or 1)
