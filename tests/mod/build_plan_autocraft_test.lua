-- Offline tests for build_plan's automatic preparation of placeable items.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

local crafted = {}
local inventory = { ["transport-belt"] = 1 }
local character
character = {
  crafting_queue_size = 0,
  force = { recipes = {
    ["transport-belt"] = { name = "transport-belt", enabled = true, products = { { type = "item", name = "transport-belt", amount = 2 } } },
    ["burner-mining-drill"] = { name = "burner-mining-drill", enabled = true },
  } },
  get_item_count = function(name) return inventory[name] or 0 end,
  begin_crafting = function(args)
    crafted[args.recipe] = args.count
    character.crafting_queue_size = character.crafting_queue_size + args.count
    return args.count
  end,
}

package.loaded["scripts.companion"] = {
  require_companion = function() return character end,
  get = function() return character end,
}
package.loaded["scripts.actions.approach"] = { ensure = function() return nil end }
_G.prototypes = { item = {} }

local build_plan = require("scripts.actions.build_plan")
local task = { steps = {
  { item = "transport-belt", position = { x = 0, y = 0 } },
  { item = "transport-belt", position = { x = 1, y = 0 } },
  { item = "transport-belt", position = { x = 2, y = 0 } },
  { item = "burner-mining-drill", position = { x = 3, y = 0 } },
} }
build_plan.start(task)
check(crafted["transport-belt"] == 1 and crafted["burner-mining-drill"] == 1,
  "build_plan: crafts only as often as needed (1 belt craft makes 2 for the 2 missing belts)")
check(task._waiting_for_crafts == true and task._auto_crafted == 3,
  "build_plan: construction waits for its preparation queue (3 items prepared)")

crafted = {}
character.crafting_queue_size = 0
build_plan.start({ auto_craft = false, steps = {
  { item = "transport-belt", position = { x = 0, y = 0 } },
  { item = "transport-belt", position = { x = 1, y = 0 } },
} })
check(next(crafted) == nil, "build_plan: auto-crafting can be disabled")

-- positions are snapped to the tile grid the way the game aligns entities
local placement = require("scripts.placement")
local one = { tile_width = 1, tile_height = 1 }
local two = { tile_width = 2, tile_height = 2 }
local s1 = placement.snap(one, { x = 92, y = -12 }, 0)
check(s1.x == 92.5 and s1.y == -11.5, "snap: whole-number position of a 1x1 belt means that tile's centre")
local s2 = placement.snap(one, { x = 92.5, y = -11.5 }, 0)
check(s2.x == 92.5 and s2.y == -11.5, "snap: tile centres are unchanged")
local s3 = placement.snap(two, { x = 77, y = -14 }, 0)
check(s3.x == 77 and s3.y == -14, "snap: 2x2 drills stay on tile corners")
local s4 = placement.snap({ tile_width = 1, tile_height = 2 }, { x = 3, y = 3 }, 4)
check(s4.x == 3 and s4.y == 3.5, "snap: a 1x2 entity turned east is 2x1")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
