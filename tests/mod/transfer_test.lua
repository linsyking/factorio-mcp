-- Offline tests for transfer's belt handling (#28): extract takes items off a
-- belt tile's own lanes (belt_insert's mirror), with quality keys, all=true,
-- and the give-back of what doesn't fit the character.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

-- stubs: the real scripts.items and scripts.actions.approach are used.
_G.prototypes = { item = { coal = {}, ["iron-plate"] = {} }, quality = { normal = {}, rare = {} } }
package.loaded["scripts.actions.walk"] = {}
package.loaded["scripts.placement"] = {}
package.loaded["scripts.vision"] = { require_known = function() end }

-- A belt tile with two lanes. Items are {name, count, quality}; remove_item and
-- insert_at/can_insert_at work like LuaTransportLine's on one tile segment.
local function make_belt(items_left, items_right)
  local function line(items)
    local its = {}
    for _, it in ipairs(items) do its[#its + 1] = { name = it[1], count = it[2], quality = it[3] } end
    local function find(spec)
      for _, it in ipairs(its) do
        if it.name == spec.name and (it.quality or "normal") == (spec.quality or "normal") then return it end
      end
    end
    return {
      get_contents = function() return its end,
      remove_item = function(spec)
        local it = find(spec)
        if not it then return 0 end
        local n = math.min(it.count, spec.count or 1)
        it.count = it.count - n
        return n
      end,
      can_insert_at = function() return #its < 4 end,
      insert_at = function(_, spec)
        if #its >= 4 then return false end
        local it = find(spec)
        if it then it.count = it.count + 1 else its[#its + 1] = { name = spec.name, count = 1, quality = spec.quality } end
        return true
      end,
    }
  end
  local lines = { line(items_left), line(items_right) }
  return {
    valid = true, name = "transport-belt", type = "transport-belt",
    position = { x = 10.5, y = 10.5 },
    bounding_box = { left_top = { x = 10, y = 10 }, right_bottom = { x = 11, y = 11 } },
    get_max_transport_line_index = function() return 2 end,
    get_transport_line = function(i) return lines[i] end,
    _lines = lines,
  }
end

local belt
local capacity = math.huge -- how much the character's inventory accepts
local character = {
  valid = true, position = { x = 10, y = 10 }, reach_distance = 3,
  surface = { find_entities_filtered = function(_) return { belt } end },
  get_main_inventory = function() return nil end, -- pull() falls back to the character
  insert = function(spec) return math.min(spec.count or 1, capacity) end,
}
package.loaded["scripts.companion"] = {
  require_companion = function() return character end,
  get = function() return character end,
}

local transfer = require("scripts.actions.transfer")

local function extract(spec)
  local task = { type = "extract", target = { x = 10.5, y = 10.5 } }
  for k, v in pairs(spec) do task[k] = v end
  transfer.extract.start(task)
  return transfer.extract.tick(task)
end

local function belt_count(name, quality)
  local n = 0
  for _, l in ipairs(belt._lines) do
    for _, it in ipairs(l.get_contents()) do
      if it.name == name and (it.quality or "normal") == (quality or "normal") then n = n + it.count end
    end
  end
  return n
end

-- specific counts off the lanes
belt = make_belt({ { "coal", 3 } }, { { "coal", 1 } })
local r = extract({ items = { coal = 2 } })
check(r.status == "done" and r.detail == "took 2 coal from the transport-belt", "belt extract: takes 2 of 4 coal")
check(belt_count("coal") == 2, "belt extract: 2 coal remain on the tile")

-- asking for more than is there takes what there is
r = extract({ items = { coal = 99 } })
check(r.status == "done" and r.detail == "took 2 of 99 coal (that's all it had) from the transport-belt",
  "belt extract: shortfall reported")

-- a quality key only touches that quality
belt = make_belt({ { "iron-plate", 2 }, { "iron-plate", 3, "rare" } }, {})
r = extract({ items = { ["iron-plate@rare"] = 1 } })
check(r.status == "done" and belt_count("iron-plate", "rare") == 2 and belt_count("iron-plate") == 2,
  "belt extract: the quality key takes only that quality")

-- nothing left of a requested item
belt = make_belt({ { "coal", 1 } }, {})
r = extract({ items = { coal = 1, ["iron-plate"] = 1 } })
check(r.status == "done" and r.detail == "took 1 coal from the transport-belt; it has no iron-plate",
  "belt extract: other items on the tile are reported")

belt = make_belt({}, { { "iron-plate", 1 } })
r = extract({ items = { coal = 1 } })
check(r.status == "failed" and r.detail == "couldn't take anything from the transport-belt — it has no coal",
  "belt extract: an empty-for-that-item tile fails with the fleet's #28 message")

-- all=true empties the tile's lanes, both qualities
belt = make_belt({ { "coal", 3 }, { "iron-plate", 2, "rare" } }, { { "iron-plate", 1 } })
r = extract({ all = true })
check(r.status == "done" and r.detail == "took 1 iron-plate, 2 iron-plate@rare, 3 coal from the transport-belt",
  "belt extract: all=true takes everything on the tile")
check(belt_count("coal") == 0 and belt_count("iron-plate") == 0 and belt_count("iron-plate", "rare") == 0,
  "belt extract: the tile is empty after all=true")

-- overflow goes back onto the belt
belt = make_belt({ { "coal", 3 } }, {})
capacity = 1
r = extract({ all = true })
capacity = math.huge
check(r.status == "done" and belt_count("coal") == 2,
  "belt extract: what the character can't carry goes back on the belt")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
