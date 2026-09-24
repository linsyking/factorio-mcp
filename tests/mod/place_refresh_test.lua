-- Offline tests for place's fast_replace paths (build.lua, 0.2.18): the
-- engine has no same-name fast replace — its manual build check refuses a
-- tile held by an identical entity, so `place stone-wall over stone-wall
-- fast_replace=true` always failed at "blocked by stone-wall" at the
-- target's own position (soldier's wall-maintenance repro). Same item +
-- fast_replace is now a REFRESH: the old entity is mined back into the
-- character's inventory and the new one placed fresh. Different-name
-- fast_replace keeps using the engine's swap (contents move over).
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

_G.defines = {
  direction = { north = 0, east = 4, south = 8, west = 12 },
  build_check_type = { manual = "manual" },
}

-- ---------------------------------------------------------------- stubs
local c -- the character, rebuilt per case
local calls = {}

local function fresh_character()
  calls = {}
  return {
    force = "player",
    surface = {
      can_place_entity = function()
        calls.can_place = (calls.can_place or 0) + 1
        return true
      end,
      create_entity = function(spec)
        calls.created = spec
        return { valid = true, type = "wall", position = { x = spec.position.x, y = spec.position.y } }
      end,
    },
    get_main_inventory = function() return { tag = "inv" } end,
    remove_item = function() end,
  }
end

package.loaded["scripts.companion"] = {
  require_companion = function() return c end,
  get = function() return c end,
}
package.loaded["scripts.placement"] = {
  occupant = function(_, name) return c._occ, c._occ_items or 0 end,
  check_direction = function() return nil end,
  snap = function(_, pos) return pos end,
  footprint = function() return { { 0, 0 }, { 1, 1 } } end,
  explain = function() return "stub explanation" end,
}
package.loaded["scripts.items"] = {
  parse = function(s) return s:match("^(.-)@") or s, s:match("@(%w+)$") end,
  count = function() return 1 end,
  spec = function(name, n) return { name = name, count = n } end,
}
package.loaded["scripts.actions.approach"] = {
  ensure = function() return "ok" end,
  step_aside = function() return "ok" end,
}
package.loaded["scripts.actions.build_plan"] = {}
package.loaded["scripts.belts"] = { underground_note = function() return "stub", true end }
package.loaded["scripts.actions.craft"] = {}
package.loaded["scripts.provenance"] = { record = function() end }
_G.prototypes = {
  item = { ["stone-wall"] = { place_result = { name = "stone-wall" } } },
  entity = { ["stone-wall"] = {} },
}

local build = require("scripts.actions.build")

local function run_place(occ, fast_replace)
  c = fresh_character()
  c._occ = occ
  local task = {
    item = "stone-wall",
    position = { x = 103.5, y = 69.5 },
    fast_replace = fast_replace,
  }
  build.place.start(task)
  return build.place.tick(task), task
end

local function wall_at(name, quality)
  local w = {
    name = name, valid = true,
    position = { x = 103.5, y = 69.5 },
    quality = quality and { name = quality } or { name = "normal" },
    mined = nil,
  }
  -- the engine binds mine to its entity: e.mine({...}) carries no self
  w.mine = function(opts)
    w.mined = opts
    return true
  end
  return w
end

-- the bug: same-name fast_replace refreshes instead of failing
do
  local old = wall_at("stone-wall")
  local r = run_place(old, true)
  check(r.status == "done", "wall-over-wall fast_replace succeeds (the 0.2.17-and-earlier failure)")
  check(old.mined ~= nil and old.mined.inventory ~= nil, "the old wall is mined into the character's inventory")
  check(calls.can_place == nil, "the engine's can_place gate is skipped for a same-name refresh")
  check(calls.created.fast_replace == nil and calls.created.character == nil,
    "the refresh places fresh, not as an engine fast-replace swap")
  check(r.detail:find("replaced the old one", 1, true) ~= nil,
    "the result says the old one was replaced ('" .. r.detail .. "')")
end

-- no fast_replace keeps the helpful in-the-way error
do
  local r = run_place(wall_at("stone-wall"), nil)
  check(r.status == "failed" and r.detail:find("is in the way", 1, true) ~= nil,
    "without fast_replace the occupant error stands ('" .. tostring(r.detail) .. "')")
end

-- different entity with fast_replace: the engine swap, gate and all
do
  local r = run_place(wall_at("stone-furnace"), true)
  check(r.status == "done" and calls.can_place == 1, "a different-name fast_replace still passes the engine gate")
  check(calls.created.fast_replace == true and calls.created.character == c,
    "a different-name fast_replace still uses the engine swap (contents move over)")
  check(r.detail:find("replaced the old one", 1, true) == nil,
    "no refresh note on an engine swap ('" .. r.detail .. "')")
end

-- quality mismatch is not a refresh: engine path decides
do
  local r = run_place(wall_at("stone-wall", "uncommon"), true)
  check(r.status == "done" and calls.can_place == 1 and calls.created.fast_replace == true,
    "a quality mismatch goes to the engine's quality fast-replace")
end

-- mine failure (inventory full) fails the job honestly
do
  c = fresh_character()
  local old = wall_at("stone-wall")
  old.mine = function() return false end
  c._occ = old
  local task = { item = "stone-wall", position = { x = 103.5, y = 69.5 }, fast_replace = true }
  build.place.start(task)
  local r = build.place.tick(task)
  check(r.status == "failed" and r.detail:find("couldn't take down", 1, true) ~= nil,
    "a failed take-down fails the job with the reason ('" .. tostring(r.detail) .. "')")
end

os.exit(failures == 0 and 0 or 1)
