-- Offline tests for drill-output visibility: scan_area's drill footer
-- (position, facing, the ONE output tile, what stands there — EMPTY and
-- DEAD first) and layout_context's drills list for check_plan. Ground truth
-- from the coal-field audit: a drill outputs to exactly one tile, the middle
-- tile of its facing side next to the footprint — the drill at (30.5, -14.5)
-- facing west feeds the belt at (28.5, -14.5), a belt anywhere else collects
-- nothing.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

_G.storage = {}
_G.game = { tick = 0, forces = { enemy = { name = "enemy" } } }
local S = { working = 1, no_minable_resources = 2, waiting_for_space_in_destination = 3 }
_G.defines = { entity_status = S }

local my_force = { name = "player" }

-- entities standing at exact positions (thing_at / what_at look them up by
-- querying the position)
local AT = {}
local function put(x, y, e) AT[string.format("%.2f,%.2f", x, y)] = e end
local belt = { valid = true, name = "transport-belt", type = "transport-belt" }
local chest = { valid = true, name = "iron-chest", type = "container" }

local in_area_drills, in_area_belts, scan_box = {}, {}, {}

local surface = {
  name = "nauvis",
  get_tile = function() error("no tiles in the stub") end,
  find_entities_filtered = function(filter)
    if filter.position then
      local e = AT[string.format("%.2f,%.2f", filter.position.x, filter.position.y)]
      return e and { e } or {}
    end
    if filter.type == "mining-drill" then return in_area_drills end
    if type(filter.type) == "table" then return in_area_belts end
    return scan_box
  end,
}

local character = {
  position = { x = 30, y = -13 },
  force = my_force,
  surface = surface,
}
package.loaded["scripts.companion"] = {
  require_companion = function() return character end,
  get = function() return character end,
}
package.loaded["scripts.vision"] = {
  is_known = function(_, _, pos) return pos.x < 46 end, -- beyond x=46 is fog
  filter_perceivable = function(entities) return entities end,
  filter_known = function(entities) return entities end,
}

local spatial = require("scripts.spatial")

local function mk_drill(name, x, y, direction, drop_x, drop_y, status, half)
  return {
    valid = true, name = name, type = "mining-drill", force = my_force,
    position = { x = x, y = y }, direction = direction,
    drop_position = { x = drop_x, y = drop_y }, status = status,
    bounding_box = {
      left_top = { x = x - half, y = y - half },
      right_bottom = { x = x + half, y = y + half },
    },
  }
end

-- ------------------------------------------------------------ scan_area
-- the coal field: a dead drill (belted, ore gone), a burner drill with
-- nothing at its output, a healthy one feeding its belt
put(27.65, -9.5, belt)   -- the dead drill's output tile
put(28.65, -14.5, belt)  -- the healthy drill's output tile
scan_box = {
  mk_drill("electric-mining-drill", 29.5, -9.5, 12, 27.65, -9.5, S.no_minable_resources, 1.5),
  mk_drill("burner-mining-drill", 34, -20, 0, 33.5, -21.3, S.working, 1),
  mk_drill("electric-mining-drill", 30.5, -14.5, 12, 28.65, -14.5, S.working, 1.5),
}

local r = spatial.scan_area({ center = { x = 30, y = -13 }, radius = 15 })
check(r.origin.x == 15 and r.origin.y == -28 and r.width == 31, "scan: the usual box around the centre")
check(#r.drills == 3, "scan: every drill in the area is listed")
local dead, empty, healthy = r.drills[1], r.drills[2], r.drills[3]
check(dead.name == "electric-mining-drill" and dead.status == "no_minable_resources"
  and dead.direction == 12 and dead.output.x == 27.5 and dead.output.y == -9.5
  and dead.output_into == "transport-belt",
  "scan: the DEAD drill comes first — position, facing, output tile, receiver")
check(empty.name == "burner-mining-drill" and empty.output_into == "nothing"
  and empty.output.x == 33.5 and empty.output.y == -21.5,
  "scan: the drill with an EMPTY output tile comes second, output tile rounded to the tile centre")
check(healthy.status == "working" and healthy.output.x == 28.5 and healthy.output.y == -14.5
  and healthy.output_into == "transport-belt",
  "scan: a connected drill lists last with the belt tile it feeds (the audited belt at (28.5, -14.5))")

-- the legend explains every letter on the map (the coal-field report saw
-- letters k and q with no legend entry)
local missing = {}
for _, row in ipairs(r.grid) do
  for ch in row:gmatch("%l") do
    if not r.legend[ch] then missing[#missing + 1] = ch end
  end
end
check(#missing == 0, "scan: every lowercase letter in the grid has a legend entry")
check(r.legend.a == "electric-mining-drill" and r.legend.b == "burner-mining-drill",
  "scan: drill letters are assigned and explained")

-- -------------------------------------------------------- layout_context
put(28.65, -14.5, chest) -- now a chest receives the healthy drill's output
put(28.5, -17.5, belt)   -- an at-point on a belt
in_area_drills = {
  mk_drill("electric-mining-drill", 30.5, -14.5, 12, 28.65, -14.5, S.working, 1.5),
  mk_drill("burner-mining-drill", 50, 4, 0, 47.5, 3.5, S.working, 1),
}
local ctx = spatial.layout_context({ area = { 15, -28, 45, 2 }, points = { { x = 28.5, y = -17.5 } } })
check(#ctx.drills == 2, "layout_context: drills in the area are listed")
local a, b = ctx.drills[1], ctx.drills[2]
check(a.x == 30.5 and a.y == -14.5 and a.name == "electric-mining-drill" and a.direction == 12
  and a.drop.x == 28.65 and a.drop.y == -14.5 and a.drop_into == "iron-chest"
  and a.drop_into_type == "container" and a.status == "working",
  "layout_context: the drill, its output point, the receiver there (name and type) and its status")
check(b.drop_into == "unexplored" and b.drop_into_type == nil,
  "layout_context: an output tile on unexplored ground says so")
check(ctx.at[1] == "transport-belt", "layout_context: at-points still resolve as before")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
