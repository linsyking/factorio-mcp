-- Offline tests for scripts/belts.lua: trace_belt and the measure_belt job.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

_G.game = { tick = 0 }
-- A line of south-facing belts at x=0.5, y = 0.5 .. 2.5, then nothing (dead end).
local belts, by_pos = {}, {}
local uid = 0
local function mk(y)
  uid = uid + 1
  local b = { valid = true, unit_number = uid, type = "transport-belt", name = "transport-belt", direction = 8,
    position = { x = 0.5, y = y }, prototype = { belt_speed = 0.03125 }, lanes = { {}, {} } }
  b.get_max_transport_line_index = function() return 2 end
  b.get_transport_line = function(i)
    return {
      get_contents = function()
        local c = {}
        for _, it in ipairs(b.lanes[i]) do c[#c + 1] = { name = it.name, count = 1 } end
        return c
      end,
      get_detailed_contents = function()
        local c = {}
        for _, it in ipairs(b.lanes[i]) do c[#c + 1] = { stack = { name = it.name, count = 1 }, unique_id = it.id, position = 0 } end
        return c
      end,
    }
  end
  belts[#belts + 1] = b
  by_pos[y] = b
  return b
end
local b1, b2, b3 = mk(0.5), mk(1.5), mk(2.5)
b1.belt_neighbours = { inputs = {}, outputs = { b2 } }
b2.belt_neighbours = { inputs = { b1 }, outputs = { b3 } }
b3.belt_neighbours = { inputs = { b2 }, outputs = {} }
b2.lanes[1] = { { name = "iron-ore", id = 1 }, { name = "iron-ore", id = 2 } }
local drill = { valid = true, type = "mining-drill", name = "burner-mining-drill", position = { x = 1, y = 0 },
  drop_position = { x = 0.5, y = 0.5 } }
local ins = { valid = true, type = "inserter", name = "burner-inserter", position = { x = 1.5, y = 2.5 },
  pickup_position = { x = 0.5, y = 2.5 }, drop_position = { x = 2.5, y = 2.5 } }

local surface = {
  find_entities_filtered = function(f)
    if f.type and type(f.type) == "table" and f.type[1] == "inserter" then return { drill, ins } end
    if f.type then -- belts near a point
      local out = {}
      for _, b in ipairs(belts) do
        if math.abs(b.position.x - f.position.x) < 1 and math.abs(b.position.y - f.position.y) < 1 then out[#out + 1] = b end
      end
      return out
    end
    return {} -- nothing in front of the dead end
  end,
}
local char = { valid = true, surface = surface, force = { belt_stack_size_bonus = 0 }, position = { x = 0, y = 0 } }
package.loaded["scripts.companion"] = { require_companion = function() return char end, get = function() return char end }
package.loaded["scripts.vision"] = { require_known = function() end, is_known = function() return true end }
package.loaded["scripts.actions.approach"] = {
  pick_entity = function(cands, p)
    local best, bd
    for _, e in ipairs(cands) do
      local d = (e.position.x - p.x) ^ 2 + (e.position.y - p.y) ^ 2
      if not bd or d < bd then best, bd = e, d end
    end
    return best
  end,
}

local belts_mod = require("scripts.belts")
local r = belts_mod.trace({ position = { x = 0.5, y = 1.5 } })
check(r.tiles == 3 and #r.legs == 1 and r.legs[1].moving == "south", "trace: follows the line both ways (3 tiles, one leg moving south)")
check(r.legs[1].left_side == "east" and r.legs[1].left["iron-ore"] == 2 and r.legs[1].fill_left == 17,
  "trace: lanes named by travel with compass side; items and fill % per lane")
check(r.ends:find("dead end", 1, true) ~= nil, "trace: a belt facing nothing is reported as a dead end")
check(r.begins:find("nothing feeds it", 1, true) ~= nil, "trace: the start is reported")
check(#r.fed_by == 1 and r.fed_by[1]:find("burner-mining-drill", 1, true) and #r.taken_by == 1,
  "trace: the drill dropping onto it and the inserter picking from it are listed")
check(r.lane_capacity_per_min == 450, "trace: yellow belt capacity 450/min per lane")

-- measure: items flowing through b2 on the left lane at 3 per second
local job = { type = "measure_belt", target = { x = 0.5, y = 1.5 }, seconds = 4 }
belts_mod.measure.start(job)
local next_id, res = 100, nil
for t = 1, 4 * 60 + 2 do
  game.tick = game.tick + 1
  if t % 20 == 0 then -- a new item every 20 ticks, the oldest one leaves
    next_id = next_id + 1
    table.insert(b2.lanes[1], { name = "iron-ore", id = next_id })
    if #b2.lanes[1] > 4 then table.remove(b2.lanes[1], 1) end
  end
  res = belts_mod.measure.tick(job)
  if res then break end
end
check(res and res.status == "done" and res.detail:find("flowing", 1, true) and res.detail:find("180/min", 1, true),
  "measure: counts items that pass (3/s = 180/min on the left lane) and says it's flowing")

-- measure: a full lane that never moves is reported as backed up
b2.lanes[1] = { { name = "iron-ore", id = 900 }, { name = "iron-ore", id = 901 }, { name = "iron-ore", id = 902 } }
local job2 = { type = "measure_belt", target = { x = 0.5, y = 1.5 }, seconds = 3 }
belts_mod.measure.start(job2)
local res2
for _ = 1, 3 * 60 + 2 do
  game.tick = game.tick + 1
  res2 = belts_mod.measure.tick(job2)
  if res2 then break end
end
check(res2 and res2.detail:find("NOT MOVING", 1, true) and res2.detail:find("0/min", 1, true),
  "measure: items that stay put are reported as backed up, 0/min")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
