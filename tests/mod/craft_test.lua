-- Offline tests for scripts/actions/craft.lua (0.2.16 reporting fixes):
-- chain-aware partial-start notes, queue depth, made-vs-pocket results,
-- full-inventory stall detection, and the cancel event that reports what was
-- already crafted (the "windfall" intermediates).
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end
local function has(s, sub) return type(s) == "string" and string.find(s, sub, 1, true) ~= nil end

_G.game = { tick = 1000 }

local pushed = {}
local produced = {}

local c = {}
package.preload["scripts.companion"] = function()
  return {
    require_companion = function() return c end,
    get = function() return c end,
    context = function() return "tester" end,
  }
end
package.preload["scripts.events"] = function()
  return { push = function(kind, text) pushed[#pushed + 1] = kind .. ": " .. text end }
end
package.preload["scripts.stats"] = function()
  return { record_produced = function(_, name, n) produced[#produced + 1] = n .. " " .. name end }
end

local craft = require("scripts.actions.craft")

local function reset()
  pushed, produced = {}, {}
  c = {
    counts = {},
    craftable = 0,
    started_return = 0,
    crafting_queue_size = 0,
    crafting_queue = {},
    empty_stacks = 10,
    prototype = { crafting_categories = { crafting = true } },
    force = {
      recipes = {
        ["stone-wall"] = {
          enabled = true, category = "crafting",
          ingredients = { { type = "item", name = "stone-brick", amount = 5 } },
          products = { { type = "item", name = "stone-wall", amount = 1 } },
        },
        ["small-electric-pole"] = {
          enabled = true, category = "crafting",
          ingredients = {
            { type = "item", name = "copper-plate", amount = 1 },
            { type = "item", name = "wood", amount = 1 },
          },
          products = { { type = "item", name = "small-electric-pole", amount = 2 } },
        },
      },
    },
  }
  c.get_item_count = function(name) return c.counts[name] or 0 end
  c.get_craftable_count = function() return c.craftable end
  c.begin_crafting = function() return c.started_return end
  c.get_main_inventory = function()
    return {
      count_empty_stacks = function() return c.empty_stacks end,
      get_contents = function()
        local out = {}
        for k, v in pairs(c.counts) do out[#out + 1] = { name = k, count = v } end
        return out
      end,
    }
  end
  c.cancel_crafting = function(spec)
    local q = c.crafting_queue
    q[#q] = nil
    c.crafting_queue_size = c.crafting_queue_size - spec.count
    c.counts["stone-brick"] = (c.counts["stone-brick"] or 0) + spec.count * 5
  end
  _G.game.tick = 1000
end

local function advance(task)
  _G.game.tick = _G.game.tick + 30
  return craft.tick(task)
end

-- 1. partial start: the note names the chain ceiling, the direct shortfall,
--    and that crafts draw from what you carry (stone's r34 report)
reset()
c.counts["stone-brick"] = 222
c.craftable = 44
c.started_return = 44
local task = { recipe = "stone-wall", count = 100 }
craft.start(task)
check(has(task._craft.note, "only started 44 of 100"), "craft: partial start is stated")
check(has(task._craft.note, "278x stone-brick"), "craft: direct shortfall uses the recipe amounts (500-222)")
check(has(task._craft.note, "materials for 44"), "craft: the chain-aware ceiling is in the note")
check(has(task._craft.note, "not from chests"), "craft: the note says crafts draw from what you carry")

-- 2. the queue depth after begin_crafting, with the auto-queued intermediates
reset()
c.started_return = 100
c.crafting_queue_size = 283
c.crafting_queue = {
  { recipe = "stone-wall", count = 100 },
  { recipe = { name = "inserter" }, count = 120 },
  { recipe = "electronic-circuit", count = 40 },
  { recipe = "copper-cable", count = 23 },
}
task = { recipe = "stone-wall", count = 100 }
craft.start(task)
check(has(task._craft.note, "the queue holds 283 crafts now"), "craft: queue depth after begin is reported")
check(has(task._craft.note, "auto-queued intermediates: copper-cable, electronic-circuit, inserter"),
  "craft: intermediates are named (string and table recipe forms)")

-- 3. near-full inventory warning at start
reset()
c.started_return = 20
c.empty_stacks = 1
task = { recipe = "stone-wall", count = 20 }
craft.start(task)
check(has(task._craft.note, "WARNING: inventory nearly full"), "craft: near-full inventory warns at start")

-- 4. done, multi-output recipe: made items with the per-craft yield
reset()
c.started_return = 2
task = { recipe = "small-electric-pole", count = 2 }
craft.start(task)
c.counts["small-electric-pole"] = 4 -- the queue produced 4 poles
local r = advance(task)
check(r and r.status == "done", "craft: multi-output craft finishes when the queue drains")
check(r.detail == "crafted 2x small-electric-pole -> 4 small-electric-pole (2 per craft)",
  "craft: made counts recipe results, not executions")
check(#produced == 1 and produced[1] == "4 small-electric-pole", "craft: production stats record items made")

-- 5. done, pocket differs from made (the character used some mid-craft)
reset()
c.started_return = 20
c.counts["stone-wall"] = 84
task = { recipe = "stone-wall", count = 20 }
craft.start(task)
c.counts["stone-wall"] = 100 -- 20 crafted, 4 used while it ran
r = advance(task)
check(r.status == "done" and has(r.detail, "crafted 20x stone-wall -> 20 stone-wall"),
  "craft: the done line reports items made")
check(has(r.detail, "stone-wall +16 in pocket"), "craft: the pocket delta is the net count")
check(has(r.detail, "net of any you used while it ran"), "craft: the net delta is labeled as such")
check(#produced == 1 and produced[1] == "20 stone-wall", "craft: stats record made, not the net pocket delta")

-- 6. stall: a frozen queue with a full inventory fails with instructions
reset()
c.started_return = 100
task = { recipe = "stone-wall", count = 100 }
craft.start(task)
c.crafting_queue_size = 63
c.empty_stacks = 0
local polls = 0
repeat
  r = advance(task)
  polls = polls + 1
until r ~= nil or polls > 60
check(r and r.status == "failed" and has(r.detail, "crafting stalled"), "craft: a stalled queue fails the job")
check(has(r.detail, "63 crafts queued") and has(r.detail, "no progress for 20s"),
  "craft: the stall message says how many crafts and how long")
check(has(r.detail, "inventory is full (0 free slots)"), "craft: the stall message names the full inventory")
check(polls == 41, "craft: the stall fires after 40 frozen polls, not before (" .. polls .. " polls)")

-- 7. no stall failure while the inventory has room (progress or not)
reset()
c.started_return = 100
task = { recipe = "stone-wall", count = 100 }
craft.start(task)
c.crafting_queue_size = 63
c.empty_stacks = 10
local nils = 0
for _ = 1, 60 do
  r = advance(task)
  if r == nil then nils = nils + 1 end
end
check(nils == 60, "craft: a frozen queue with inventory room does not fail")

-- 8. queue progress resets the stall watch
reset()
c.started_return = 100
task = { recipe = "stone-wall", count = 100 }
craft.start(task)
c.empty_stacks = 0
local bad = nil
for i = 1, 80 do
  c.crafting_queue_size = (i % 10 == 0) and 63 - i or 63
  r = advance(task)
  if r and r.status == "failed" then bad = r.detail break end
end
check(bad == nil, "craft: any queue movement resets the stall watch")

-- 9. stop(): the cancel event reports refunds and crafted-but-kept items
reset()
c.started_return = 20
c.counts["stone-wall"] = 84
c.counts["stone-brick"] = 222
task = { recipe = "stone-wall", count = 20 }
craft.start(task) -- pocket snapshot: 84 stone-wall, 222 stone-brick
c.crafting_queue_size = 13
c.crafting_queue = { { index = 1, count = 13, recipe = "stone-wall" } }
c.counts["stone-wall"] = 90 -- 6 crafted and kept
c.counts["stone-brick"] = 157 -- 65 spent on queued crafts; the refund brings 222 back
c.counts["copper-cable"] = 30 -- an intermediate crafted on the way
craft.stop(task)
check(#pushed == 1 and pushed[1]:find("craft_cancelled", 1, true), "craft: cancelling pushes one event")
check(has(pushed[1], "13 queued crafts refunded"), "craft: the event counts refunded crafts")
check(has(pushed[1], "already crafted, kept: +30 copper-cable, +6 stone-wall"),
  "craft: kept products and intermediates are listed")

-- 10. a craft that can't start at all names the pocket rule
reset()
c.counts["stone-brick"] = 10
task = { recipe = "stone-wall", count = 100 }
local ok, err = pcall(craft.start, task)
check(not ok and has(tostring(err), "not from chests"), "craft: a zero-start error mentions the pocket rule")

os.exit(failures == 0 and 0 or 1)
