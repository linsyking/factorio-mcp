-- Offline tests for the 2.0 line-scoped belt reads (0.2.22): a transport
-- line is read per belt entity, but the internal line it wraps CAN span
-- multiple tiles (line_equals is true across different owners) — every tile
-- of a line reports the same items. trace_belt counts each line once (fill %
-- against the line's line_length — NOT total_segment_length, which is the
-- larger segment scope: against it a 49-tile lab-spine leg read 1% full
-- while holding 83%), a line carries its items through corner legs,
-- per-tile lines (the lab-site reality) sum per tile with fill against the
-- tiles, measure_belt says when items sit on the line but nothing new
-- entered it, and belt_insert lands items on the TARGET tile (raw line
-- positions address the whole line, not the tile).
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

_G.game = { tick = 0 }
_G.prototypes = { item = { coal = {}, ["iron-ore"] = {}, ["copper-ore"] = {} }, quality = { normal = {} } }
package.loaded["scripts.actions.walk"] = {}
package.loaded["scripts.placement"] = {}
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

local world = { char = nil }
package.loaded["scripts.companion"] = {
  require_companion = function() return world.char end,
  get = function() return world.char end,
}

-- one internal line shared by every belt of a run. line_length is the
-- line's own span (the fill denominator); total_segment_length is a DECOY
-- carrying the live lab spine's real 61 — the fill must not touch it (the
-- segment is this line plus everything directly connected front and back).
local function mkline(len, left, right)
  local function lane(items)
    return {
      get_contents = function() return items end,
      line_equals = function(self, other) return self == other end,
      line_length = len,
      total_segment_length = 61,
    }
  end
  return { lanes = { lane(left), lane(right) } }
end

local function belt(x, y, dir, line, uid)
  return {
    valid = true, unit_number = uid, type = "transport-belt", name = "transport-belt",
    direction = dir, position = { x = x, y = y }, prototype = { belt_speed = 0.03125 },
    get_max_transport_line_index = function() return 2 end,
    get_transport_line = function(i) return line.lanes[i] end,
    belt_neighbours = {},
  }
end

local function chain(...)
  local bs = { ... }
  for i, b in ipairs(bs) do
    b.belt_neighbours.inputs = i > 1 and { bs[i - 1] } or {}
    b.belt_neighbours.outputs = i < #bs and { bs[i + 1] } or {}
  end
  return bs
end

local function setworld(bs)
  local surface = {
    find_entities_filtered = function(f)
      if f.type and type(f.type) == "table" and f.type[1] == "inserter" then return {} end
      if f.type then -- belts near a point
        local out = {}
        for _, b in ipairs(bs) do
          if math.abs(b.position.x - f.position.x) < 1 and math.abs(b.position.y - f.position.y) < 1 then
            out[#out + 1] = b
          end
        end
        return out
      end
      return {}
    end,
  }
  world.char = { valid = true, surface = surface, force = { belt_stack_size_bonus = 0 }, position = { x = 0, y = 0 } }
end

local belts_mod = require("scripts.belts")

-- one line spanning 3 tiles: 10 iron on the left lane. Every tile reports
-- the line's 10 items; the trace must count 10, not 30, and fill against
-- the line's 3 tiles.
do
  local line = mkline(3, { { name = "iron-ore", count = 10 } }, {})
  local bs = chain(belt(0.5, 0.5, 8, line, 1), belt(0.5, 1.5, 8, line, 2), belt(0.5, 2.5, 8, line, 3))
  setworld(bs)
  local r = belts_mod.trace({ position = { x = 0.5, y = 1.5 } })
  check(#r.legs == 1 and r.tiles == 3, "one straight run of 3 tiles")
  check(r.legs[1].n_left == 10 and r.legs[1].left["iron-ore"] == 10,
    "a shared line is counted once, not per tile (10 items, not 30)")
  check(r.legs[1].fill_left == 83, "fill measured against the line's length (10 of 12 = 83%, not 4% against the 61-tile segment)")
  check(r.legs[1].n_right == 0 and r.legs[1].fill_right == 0, "empty lane reads 0")
end

-- per-tile lines (the lab-site reality: line_equals false between
-- neighbours): every tile's items are its own, fill against the tiles
do
  local bs = {}
  for i = 0, 2 do
    local l = mkline(1, { { name = "iron-ore", count = 4 } }, {})
    bs[#bs + 1] = belt(0.5, i + 0.5, 8, l, 40 + i)
  end
  chain(bs[1], bs[2], bs[3])
  setworld(bs)
  local r = belts_mod.trace({ position = { x = 0.5, y = 1.5 } })
  check(r.legs[1].n_left == 12 and r.legs[1].left["iron-ore"] == 12,
    "per-tile lines: each tile's items are its own (3 x 4 = 12, nothing merged away)")
  check(r.legs[1].fill_left == 100, "per-tile lines: fill against the walked tiles (12 of 12), not the segment")
end

-- a line continuing through a corner: both legs carry the line's items/fill
do
  local line = mkline(3, {}, { { name = "copper-ore", count = 8 } })
  local a, b, c = belt(0.5, 0.5, 8, line, 11), belt(0.5, 1.5, 8, line, 12), belt(1.5, 1.5, 4, line, 13)
  chain(a, b, c)
  setworld({ a, b, c })
  local r = belts_mod.trace({ position = { x = 0.5, y = 0.5 } })
  check(#r.legs == 2 and r.legs[1].tiles == 2 and r.legs[2].tiles == 1, "the corner splits legs, not the line")
  check(r.legs[1].n_right == 8 and r.legs[2].n_right == 8,
    "a line carries its items into every leg it touches (counted once, shown in both)")
  check(r.legs[1].fill_right == 67 and r.legs[2].fill_right == 67, "both legs fill against the line's 3 tiles (8/12)")
end

-- two lines in one leg (a side-load splits them): 4 + 2 items, lengths 2 + 1
do
  local l1 = mkline(2, { { name = "iron-ore", count = 4 } }, {})
  local l2 = mkline(1, { { name = "iron-ore", count = 2 } }, {})
  local bs = chain(belt(0.5, 5.5, 8, l1, 21), belt(0.5, 6.5, 8, l1, 22), belt(0.5, 7.5, 8, l2, 23))
  setworld(bs)
  local r = belts_mod.trace({ position = { x = 0.5, y = 5.5 } })
  check(r.legs[1].n_left == 6, "two lines in one leg: 4 + 2 items")
  check(r.legs[1].fill_left == 50, "fill against both lines' lengths (6 of 12)")
end

-- measure: items on the run, none new entered — said honestly, not "empty"
do
  local state = {
    items = { { name = "coal", count = 3 }, { name = "coal", count = 2 } },
    det = { { stack = { name = "coal", count = 3 }, unique_id = 1, position = 0.2 },
      { stack = { name = "coal", count = 2 }, unique_id = 2, position = 0.4 } },
  }
  local lane1 = {
    get_contents = function() return state.items end,
    get_detailed_contents = function() return state.det end,
    line_equals = function(self, o) return self == o end,
    line_length = 1,
    total_segment_length = 1,
  }
  local lane2 = { get_contents = function() return {} end,
    get_detailed_contents = function() return {} end }
  local mb = {
    valid = true, unit_number = 31, type = "transport-belt", name = "transport-belt",
    direction = 8, position = { x = 9.5, y = 0.5 }, prototype = { belt_speed = 0.03125 },
    get_max_transport_line_index = function() return 2 end,
    get_transport_line = function(i) return i == 1 and lane1 or lane2 end,
    belt_neighbours = {},
  }
  setworld({ mb })
  local task = { type = "measure_belt", target = { x = 9.5, y = 0.5 }, seconds = 2 }
  game.tick = 0
  belts_mod.measure.start(task)
  belts_mod.measure.tick(task) -- first sample: the baseline
  table.remove(state.det, 1)  -- one item flows off the run; none enters
  state.items = { { name = "coal", count = 2 } }
  game.tick = 120
  local res = belts_mod.measure.tick(task)
  check(res and res.status == "done" and res.detail:find("nothing NEW entered", 1, true)
    and res.detail:find("2 item(s) were already on it", 1, true),
    "measure: items on the line with no new arrivals is not plain 'empty'")
end

-- belt_insert: items land on the TARGET tile, not wherever the line's
-- coordinate origin sits
local transfer = require("scripts.actions.transfer")
do
  local inserted = {}
  local ins_line = {
    line_length = 2, -- a 2-tile run: this belt is its second tile
    get_line_item_position = function(p) return { x = 5.5, y = p } end,
    can_insert_at = function() return true end,
    insert_at = function(at, spec)
      inserted[#inserted + 1] = { at = at, name = spec.name }
      return true
    end,
    get_contents = function() return {} end,
  }
  local ib = {
    valid = true, type = "transport-belt", name = "transport-belt", position = { x = 5.5, y = 1.5 },
    get_max_transport_line_index = function() return 1 end,
    get_transport_line = function() return ins_line end,
  }
  local n = transfer.entity_insert(ib, { name = "coal", count = 3, quality = "normal" })
  check(n == 3, "belt_insert inserts all requested items")
  check(#inserted == 3 and inserted[1].at == 1.875 and inserted[2].at == 1.625 and inserted[3].at == 1.375,
    "belt_insert places items within the target tile's span on the line (base 1.5 +/- offsets)")
end

-- ... and falls back to the raw slots when the mapping API is unavailable
do
  local ats = {}
  local plain = {
    can_insert_at = function() return true end,
    insert_at = function(at)
      ats[#ats + 1] = at
      return true
    end,
    get_contents = function() return {} end,
  }
  local fb = {
    valid = true, type = "transport-belt", name = "transport-belt", position = { x = 5.5, y = 1.5 },
    get_max_transport_line_index = function() return 1 end,
    get_transport_line = function() return plain end,
  }
  local n = transfer.entity_insert(fb, { name = "coal", count = 3, quality = "normal" })
  check(n == 3 and #ats == 3 and ats[1] == 0.875 and ats[2] == 0.625 and ats[3] == 0.375,
    "belt_insert falls back to the raw slots when line positions can't be mapped")
end

print(failures == 0 and "belt_segments_test: all ok" or ("belt_segments_test: " .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
