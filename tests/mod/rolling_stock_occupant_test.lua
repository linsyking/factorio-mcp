-- Offline tests for placement.occupant with rolling stock (0.2.23): rails
-- under a locomotive/wagon are its foundation, not an occupant. Before the
-- fix every locomotive placement failed with "the straight-rail at ... is in
-- the way". Other entities in the footprint still count, and rails still
-- count for anything that isn't rolling stock.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

local function box(w, h) return { left_top = { x = -w / 2, y = -h / 2 }, right_bottom = { x = w / 2, y = h / 2 } } end
_G.prototypes = { entity = {
  locomotive = { name = "locomotive", type = "locomotive", collision_box = box(1.2, 5.2) },
  ["cargo-wagon"] = { name = "cargo-wagon", type = "cargo-wagon", collision_box = box(1.2, 4.8) },
  ["wooden-chest"] = { name = "wooden-chest", type = "container", collision_box = box(0.7, 0.7) },
} }

local placement = require("scripts.placement")

local function ent(type, name, x, y, items)
  return {
    valid = true, type = type, name = name, position = { x = x, y = y },
    get_max_inventory_index = function() return items and 1 or 0 end,
    get_inventory = function() return { get_item_count = function() return items or 0 end } end,
  }
end

local function character(entities)
  return { force = "player", surface = { find_entities_filtered = function() return entities end } }
end

-- locomotive over a straight rail: no occupant
local c = character({ ent("straight-rail", "straight-rail", 61, -123) })
check(placement.occupant(c, "locomotive", { x = 64, y = -123 }, 4) == nil,
  "rails under a locomotive are not an occupant")
check(placement.occupant(c, "cargo-wagon", { x = 57, y = -123 }, 4) == nil,
  "rails under a cargo wagon are not an occupant")

-- curved rails too
c = character({ ent("curved-rail-a", "curved-rail-a", 60, -123) })
check(placement.occupant(c, "locomotive", { x = 64, y = -123 }, 4) == nil,
  "curved rails under a locomotive are not an occupant")

-- a chest in the footprint still blocks the locomotive, even with rails there
c = character({ ent("straight-rail", "straight-rail", 61, -123), ent("container", "wooden-chest", 63.5, -123.5, 5) })
local occ, n = placement.occupant(c, "locomotive", { x = 64, y = -123 }, 4)
check(occ ~= nil and occ.name == "wooden-chest" and n == 5, "a chest under a locomotive is still reported")

-- rails still count as occupants for ordinary buildings
c = character({ ent("straight-rail", "straight-rail", 61, -123) })
occ = placement.occupant(c, "wooden-chest", { x = 61.5, y = -123.5 }, 0)
check(occ ~= nil and occ.type == "straight-rail", "rails still block a chest")

-- find_entity_near (insert/extract target): a point on a train means the
-- train, not the rail under it. Live repro: "couldn't insert anything into
-- the straight-rail" when fuelling a locomotive at (45, -123).
package.loaded["scripts.actions.walk"] = {}
package.loaded["scripts.vision"] = { require_known = function() end }
local approach = require("scripts.actions.approach")

local function boxed(type, name, x, y, hw, hh)
  local e = ent(type, name, x, y)
  e.bounding_box = { left_top = { x = x - hw, y = y - hh }, right_bottom = { x = x + hw, y = y + hh } }
  return e
end
local function near_char(entities)
  local ch = { surface = { find_entities_filtered = function() return entities end } }
  return ch
end

-- the rail's centre is nearer the point than the locomotive's, and listed first
local rail = boxed("straight-rail", "straight-rail", 45, -123, 1, 1)
local loco = boxed("locomotive", "locomotive", 45.4, -123, 2.6, 0.6)
local picked = approach.find_entity_near(near_char({ rail, loco }), { x = 45, y = -123 })
check(picked == loco, "a point on a locomotive picks the locomotive, not the rail under it")

-- only a rail there: the rail is still found
picked = approach.find_entity_near(near_char({ rail }), { x = 45, y = -123 })
check(picked == rail, "a bare rail is still picked when nothing stands on it")

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("all passed")
