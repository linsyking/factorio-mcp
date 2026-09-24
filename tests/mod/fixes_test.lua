-- Offline tests for fixes from an agent's bug report (2026-09-23):
-- entity picking by footprint, and the wait_until job.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

-- stubs
_G.game = { tick = 0 }
_G.prototypes = { item = { ["iron-plate"] = {} } }
local inv = { ["iron-plate"] = 0 }
local found = {}
local char = {
  valid = true, position = { x = 0, y = 0 },
  surface = { find_entities_filtered = function() return found end },
  force = { technologies = { automation = { researched = false } } },
}
package.loaded["scripts.companion"] = { require_companion = function() return char end, get = function() return char end }
package.loaded["scripts.vision"] = { require_known = function() end }
package.loaded["scripts.actions.walk"] = {}
package.loaded["scripts.placement"] = {}
package.loaded["scripts.items"] = {
  parse = function(k) return k end,
  count = function(_, k) return inv[k] or 0 end,
}

local approach = require("scripts.actions.approach")

-- 2x2 furnaces stacked vertically: centres (80,-10) and (80,-8)
local function furnace(x, y)
  return { valid = true, name = "stone-furnace", type = "furnace", position = { x = x, y = y },
    bounding_box = { left_top = { x = x - 1, y = y - 1 }, right_bottom = { x = x + 1, y = y + 1 } } }
end
local a, b = furnace(80, -10), furnace(80, -8)
-- a chest whose centre is nearer to the point than the furnace containing it
local chest = { valid = true, name = "iron-chest", type = "container", position = { x = 81.5, y = -11.5 },
  bounding_box = { left_top = { x = 81, y = -12 }, right_bottom = { x = 82, y = -11 } } }

local e = approach.pick_entity({ chest, a }, { x = 80.6, y = -10.9 })
check(e == a, "pick: the entity whose footprint contains the point wins over a nearer centre")
-- the report's case: (80,-11) and (80,-9) both resolved to the furnace at (80,-10)
check(approach.pick_entity({ a, b }, { x = 80, y = -11 }) == a and approach.pick_entity({ a, b }, { x = 80, y = -9 }) == b,
  "pick: whole-number points name their tile, so (80,-11) and (80,-9) resolve to different furnaces")
-- a tie the tile can't settle (the named tile is empty) is still flagged
local c1 = { valid = true, name = "iron-chest", type = "container", position = { x = 20.5, y = 25.5 },
  bounding_box = { left_top = { x = 20, y = 25 }, right_bottom = { x = 21, y = 26 } } }
local i1 = { valid = true, name = "inserter", type = "inserter", position = { x = 21.5, y = 25.5 },
  bounding_box = { left_top = { x = 21, y = 25 }, right_bottom = { x = 22, y = 26 } } }
local e2, note = approach.pick_entity({ c1, i1 }, { x = 21, y = 26 })
check(e2 ~= nil and note and note:find("edge between", 1, true), "pick: a corner shared by two entities, with the named tile empty, is flagged")
check(approach.pick_entity({ c1, i1 }, { x = 21, y = 25 }) == i1, "pick: (21,25) names the inserter's tile")
local e3, note3 = approach.pick_entity({ a, b }, { x = 80.5, y = -8.5 })
check(e3 == b and note3 == nil, "pick: a point inside one building resolves to it, no note")

-- wait_until
local wait = require("scripts.actions.wait_until")
local t = { type = "wait_until", seconds = 1 }
wait.start(t)
check(wait.tick(t) == nil, "wait_until seconds: not done at once")
game.tick = 61
check((wait.tick(t) or {}).status == "done", "wait_until seconds: done after the time")

game.tick = 100
local t2 = { type = "wait_until", item = "iron-plate", count = 10, timeout_s = 2 }
wait.start(t2)
inv["iron-plate"] = 4
check(wait.tick(t2) == nil, "wait_until item: waits while there are too few")
game.tick = 140
inv["iron-plate"] = 12
local r2 = wait.tick(t2)
check(r2 and r2.status == "done", "wait_until item: done once the count is reached")

game.tick = 200
local t3 = { type = "wait_until", research = "automation", timeout_s = 1 }
wait.start(t3)
game.tick = 300
local r3 = wait.tick(t3)
check(r3 and r3.status == "failed" and r3.detail:find("timed out", 1, true), "wait_until: fails on timeout")
local ok = pcall(wait.start, { type = "wait_until", seconds = 1, research = "automation" })
check(not ok, "wait_until: exactly one condition")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
