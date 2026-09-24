-- Offline tests for pick_up (actions/pickup.lua, 0.2.18): collect ground
-- items within a radius of a point by walking over them — the crisis gap
-- (soldier's 787-steel scatter at (55.5,95.5): dense zigzag passes collected
-- nothing, because the engine's walk-over pickup belongs to GUI players).
-- The sweep takes everything within reach each tick while walking to the
-- nearest remaining item; unknown ground is not swept; a full inventory
-- stops the job with what was taken.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

-- ---------------------------------------------------------------- stubs
local c
local walk_calls = {}

local function item_entity(name, count, x, y)
  local e = {
    name = name, valid = true, destroyed = false,
    position = { x = x, y = y },
    stack = { valid_for_read = true, name = name, count = count, quality = nil },
  }
  -- the engine binds destroy to its entity: e.destroy() carries no self
  e.destroy = function() e.destroyed = true end
  return e
end

local function fresh_character(items, pos, known_all)
  walk_calls = {}
  local world = items
  c = {
    valid = true,
    position = { x = pos.x, y = pos.y },
    force = "player",
    reach_distance = 1.5,
    surface = {
      find_entities_filtered = function(f)
        local out = {}
        for _, e in ipairs(world) do
          if e.valid and not e.destroyed then
            local dx, dy = e.position.x - f.position.x, e.position.y - f.position.y
            if dx * dx + dy * dy <= f.radius * f.radius then out[#out + 1] = e end
          end
        end
        return out
      end,
    },
    get_main_inventory = function()
      return {
        count_empty_stacks = function() return c._empty or 10 end,
        insert = function(spec)
          local room = c._room or math.huge
          local put = math.min(spec.count, room)
          c._room = room - put
          c._inv = c._inv or {}
          c._inv[spec.name] = (c._inv[spec.name] or 0) + put
          return put
        end,
      }
    end,
  }
  return c
end

package.loaded["scripts.companion"] = {
  require_companion = function() return c end,
  get = function() return c end,
}
package.loaded["scripts.actions.approach"] = {
  ensure = function(_, _, target)
    walk_calls[#walk_calls + 1] = target
    c.position = { x = target.x, y = target.y } -- arrive instantly
    return "ok"
  end,
}
package.loaded["scripts.vision"] = {
  is_known = function() return c._known_all ~= false end,
}

local pickup = require("scripts.actions.pickup")

local function run(target, radius, items, pos)
  fresh_character(items, pos or { x = 0, y = 0 })
  local task = { type = "pick_up", target = target, radius = radius }
  pickup.start(task)
  for _ = 1, 20 do
    local r = pickup.tick(task)
    if type(r) == "table" then return r end
  end
  return { status = "timeout" }
end

-- a scatter around the point, collected by walking
do
  local steel = {}
  for i = 1, 4 do steel[i] = item_entity("steel-plate", 200, 54 + i, 95) end
  steel[5] = item_entity("iron-gear-wheel", 12, 55, 96)
  local r = run({ x = 55.5, y = 95.5 }, 5, steel, { x = 50, y = 90 })
  check(r.status == "done", "a scatter is picked up (" .. r.status .. ")")
  check(r.detail:find("787 steel%-plate", 1) ~= nil or r.detail:find("800 steel%-plate") ~= nil,
    "the report counts the steel ('" .. r.detail .. "')")
  check(r.detail:find("12 iron%-gear%-wheel") ~= nil, "the report counts the gears")
  check(#walk_calls >= 2, "the character walked to the piles (" .. #walk_calls .. " legs — adjacent piles fall to one stop)")
end

-- unknown ground is not swept: no information leak, no unreachable walks
do
  local e1 = item_entity("steel-plate", 100, 1, 1)
  fresh_character({ e1 }, { x = 0, y = 0 })
  c._known_all = false
  local task = { type = "pick_up", target = { x = 0, y = 0 }, radius = 5 }
  pickup.start(task)
  local r = pickup.tick(task)
  check(r.status == "done" and r.detail:find("no ground items") ~= nil,
    "an unknown-ground item reads as nothing there ('" .. tostring(r.detail) .. "')")
end

-- nothing on the ground: honest no-op
do
  local r = run({ x = 55.5, y = 95.5 }, 5, {}, { x = 55.5, y = 95.5 })
  check(r.status == "done" and r.detail:find("no ground items") ~= nil, "an empty area is an honest no-op")
end

-- full inventory: stop with what was taken, items stay on the ground
do
  local items = { item_entity("steel-plate", 200, 0.5, 0), item_entity("steel-plate", 200, 4, 0) }
  local pos = { x = 0, y = 0 }
  fresh_character(items, pos)
  c._room = 100 -- only a partial stack fits
  c._empty = 0 -- and then the inventory is full
  local task = { type = "pick_up", target = { x = 0, y = 0 }, radius = 5 }
  pickup.start(task)
  local r
  for _ = 1, 20 do
    r = pickup.tick(task)
    if type(r) == "table" then break end
  end
  check(r.status == "failed" and r.detail:find("inventory is full") ~= nil,
    "a full inventory fails the job with the reason")
  check(r.detail:find("100 steel%-plate") ~= nil, "what did fit is reported taken ('" .. r.detail .. "')")
  check(not items[2].destroyed, "the pile that didn't fit stays on the ground")
  check(items[1].stack.count == 100, "a partially taken pile keeps its remainder")
end

-- argument validation
do
  fresh_character({}, { x = 0, y = 0 })
  local ok = pcall(pickup.start, { type = "pick_up", target = { x = 1, y = 2 }, radius = 50 })
  check(not ok, "radius above the cap is rejected")
  ok = pcall(pickup.start, { type = "pick_up", target = "nope" })
  check(not ok, "a non-position target is rejected")
  ok = pcall(pickup.start, { type = "pick_up" }) -- defaults to where I stand
  check(ok, "no target defaults to the character's position")
end

os.exit(failures == 0 and 0 or 1)
