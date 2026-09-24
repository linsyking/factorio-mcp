-- Belt checks: does a belt line do what the agent built it for?
--
--   rpc trace_belt {position}   the whole line through a tile, both ways:
--       legs (runs of one direction), how it starts and ends, what feeds it
--       (inserters, drills, side-loads) and what takes from it, and the items
--       on each lane with fill % against the lane's 4 items per tile.
--   job measure_belt {target, seconds}   watches one tile and counts the
--       items that pass, per lane, against the belt's capacity; also says
--       whether it is flowing, backed up or empty.
--
-- Lanes are named from the direction of travel ("left"/"right") with the
-- compass side they are on. Known ground only.
local companion = require("scripts.companion")
local vision = require("scripts.vision")
local approach = require("scripts.actions.approach")

local M = {}

local BELT_TYPES = { "transport-belt", "underground-belt", "splitter" }
local IS_BELT = { ["transport-belt"] = true, ["underground-belt"] = true, splitter = true }
local DIR = { [0] = "north", [4] = "east", [8] = "south", [12] = "west" }
-- left/right of travel -> compass side, per direction of travel
local SIDES = { [0] = { "west", "east" }, [4] = { "north", "south" }, [8] = { "east", "west" }, [12] = { "south", "north" } }
local MAX_TILES = 400

local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
local function pos(e) return { x = r1(e.position.x), y = r1(e.position.y) } end

local function belt_at(c, p)
  local cands = c.surface.find_entities_filtered({ position = p, radius = 1.2, type = BELT_TYPES })
  local e = approach.pick_entity(cands, p)
  return e
end

-- items on a belt's two lanes: {left = {name = n}, right = {...}}, counts
local function lanes(e)
  local out = { left = {}, right = {} }
  local n = { left = 0, right = 0 }
  pcall(function()
    for i = 1, math.min(e.get_max_transport_line_index(), 2) do
      local side = i == 1 and "left" or "right"
      for _, it in ipairs(e.get_transport_line(i).get_contents()) do
        out[side][it.name] = (out[side][it.name] or 0) + it.count
        n[side] = n[side] + it.count
      end
    end
  end)
  return out, n
end

-- Belt capacity per lane in items/s: speed (tiles/s) x 4 items per tile, x belt stacking.
local function lane_capacity(e, force)
  local speed = 0
  pcall(function() speed = e.prototype.belt_speed * 60 end)
  local stack = 1
  pcall(function() stack = 1 + (force.belt_stack_size_bonus or 0) end)
  return speed * 4 * stack
end

local UNIT = { [0] = { 0, -1 }, [4] = { 1, 0 }, [8] = { 0, 1 }, [12] = { -1, 0 } }

-- How an underground belt is paired, in words. An entrance (input) pairs with
-- the first exit of the same kind ahead of it within its reach; an exit
-- (output) with the first entrance behind it. Returns (text, paired).
function M.underground_note(e)
  if not (e and e.valid and e.type == "underground-belt") then return nil end
  local input = e.belt_to_ground_type == "input"
  local other = e.neighbours
  if other then
    return string.format("%s paired with the %s at (%.1f, %.1f)", input and "entrance" or "exit",
      input and "exit" or "entrance", other.position.x, other.position.y), true
  end
  local reach = 5
  pcall(function() reach = e.prototype.max_underground_distance or reach end)
  local u = UNIT[e.direction] or { 0, 0 }
  local sign = input and 1 or -1 -- an entrance looks ahead, an exit behind
  local want = input and "exit" or "entrance"
  local text = string.format("%s with NO %s — nothing goes through it", input and "entrance" or "exit", want)
  for k = 1, reach do
    local q = { x = e.position.x + sign * u[1] * k, y = e.position.y + sign * u[2] * k }
    for _, t in ipairs(e.surface.find_entities_filtered({ position = q, radius = 0.3, name = e.name })) do
      if t.valid and t ~= e then
        local tin = t.belt_to_ground_type == "input"
        local what = string.format("the %s at (%.1f, %.1f)", tin and "entrance" or "exit", t.position.x, t.position.y)
        if t.direction ~= e.direction then
          return string.format("%s; %s is in the way and faces %s, not %s", text, what,
            DIR[t.direction] or tostring(t.direction), DIR[e.direction] or tostring(e.direction)), false
        elseif tin == input then
          return string.format("%s; %s is in between (two %ss can't pair; the one nearer the %s takes it)",
            text, what, input and "entrance" or "exit", want), false
        elseif t.neighbours then
          return string.format("%s; %s is already paired with the %s at (%.1f, %.1f), which is closer", text, what,
            input and "entrance" or "exit", t.neighbours.position.x, t.neighbours.position.y), false
        end
      end
    end
  end
  return string.format("%s with NO %s within %d tiles %s of it — nothing goes through it",
    input and "entrance" or "exit", want, reach, DIR[input and e.direction or (e.direction + 8) % 16] or "?"), false
end

local function next_down(e)
  if e.type == "underground-belt" and e.belt_to_ground_type == "input" then
    local n = e.neighbours
    if n then return { n } end
  end
  return e.belt_neighbours.outputs or {}
end

-- The belt feeding this one from behind (a straight predecessor, or the only
-- input of a curve); other inputs are side-loads.
local function next_up(e)
  if e.type == "underground-belt" and e.belt_to_ground_type == "output" then
    local n = e.neighbours
    if n then return { n } end
  end
  local ins = e.belt_neighbours.inputs or {}
  for _, i in ipairs(ins) do
    if i.direction == e.direction then return { i } end
  end
  if #ins == 1 then return { ins[1] } end
  return {}
end

-- What's in front of a belt that outputs to nothing.
local function dead_end(c, e)
  if e.type == "underground-belt" and e.belt_to_ground_type == "input" then
    return "underground " .. M.underground_note(e)
  end
  local d = e.direction
  local u = UNIT[d] or { 0, 0 }
  local front = { x = e.position.x + u[1], y = e.position.y + u[2] }
  for _, t in ipairs(c.surface.find_entities_filtered({ position = front, radius = 0.45 })) do
    if t.valid and t.type ~= "resource" and t.type ~= "item-entity" and t.type ~= "character" then
      if t.type == "underground-belt" and t.belt_to_ground_type == "output" and t.direction == e.direction then
        return string.format("runs into the back of the underground exit at (%.1f, %.1f) — an exit only puts items out;"
          .. " to go under, this tile needs an entrance", t.position.x, t.position.y)
      end
      if IS_BELT[t.type] then
        return string.format("faces the %s at (%.1f, %.1f), which doesn't take items from this side (it points %s)",
          t.name, t.position.x, t.position.y, DIR[t.direction] or tostring(t.direction))
      end
      return string.format("faces the %s at (%.1f, %.1f) — belts can't feed buildings; an inserter must take from the belt",
        t.name, t.position.x, t.position.y)
    end
  end
  return string.format("dead end: nothing in front at (%.1f, %.1f), so items stop and back up here", front.x, front.y)
end

-- Walk one way from `start`, collecting belts in order (with a cap).
local function walk(start, step, known)
  local list, seen = {}, {}
  local e = start
  while e and e.valid and not seen[e.unit_number] and #list < MAX_TILES do
    if not known(e.position) then break end
    seen[e.unit_number] = true
    list[#list + 1] = e
    e = step(e)[1]
  end
  return list
end

function M.trace(params)
  local c = companion.require_companion()
  local p = params.position
  if type(p) ~= "table" or type(p.x) ~= "number" or type(p.y) ~= "number" then error("trace_belt needs x and y") end
  vision.require_known(c.surface, c.force, p, "the belt there")
  local start = belt_at(c, p)
  if not start then error(string.format("no belt at (%.1f, %.1f)", p.x, p.y)) end
  local function known(q) return vision.is_known(c.surface, c.force, q) end

  local down = walk(start, next_down, known)
  local up_list = walk(start, next_up, known)
  -- the line in travel order: upstream (reversed, without start) + downstream
  local line = {}
  for i = #up_list, 2, -1 do line[#line + 1] = up_list[i] end
  for _, e in ipairs(down) do line[#line + 1] = e end

  local on_line = {}
  for i, e in ipairs(line) do on_line[math.floor(e.position.x) .. "," .. math.floor(e.position.y)] = i end
  local function line_index(q) return on_line[math.floor(q.x) .. "," .. math.floor(q.y)] end

  -- legs: runs of one direction
  local legs, cur = {}, nil
  local cap = lane_capacity(start, c.force)
  for i, e in ipairs(line) do
    local items, n = lanes(e)
    local kind = e.type == "underground-belt" and ("underground " .. e.belt_to_ground_type)
      or (e.type == "splitter" and "splitter" or nil)
    if not cur or cur.direction ~= e.direction or kind or cur.kind then
      cur = { direction = e.direction, from = pos(e), to = pos(e), tiles = 0, kind = kind,
        left = {}, right = {}, n_left = 0, n_right = 0, first = i,
        note = e.type == "underground-belt" and M.underground_note(e) or nil }
      legs[#legs + 1] = cur
    end
    cur.to = pos(e)
    cur.tiles = cur.tiles + 1
    for side, t in pairs(items) do
      for name, k in pairs(t) do cur[side][name] = (cur[side][name] or 0) + k end
    end
    cur.n_left, cur.n_right = cur.n_left + n.left, cur.n_right + n.right
  end
  for _, leg in ipairs(legs) do
    local sides = SIDES[leg.direction] or { "?", "?" }
    leg.left_side, leg.right_side = sides[1], sides[2]
    leg.moving = DIR[leg.direction] or tostring(leg.direction)
    leg.fill_left = math.floor(100 * leg.n_left / (4 * leg.tiles) + 0.5)
    leg.fill_right = math.floor(100 * leg.n_right / (4 * leg.tiles) + 0.5)
    leg.first = nil
  end

  -- feeders and takers: inserters and drills touching the line, side-loads
  local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
  for _, e in ipairs(line) do
    x1, y1 = math.min(x1, e.position.x), math.min(y1, e.position.y)
    x2, y2 = math.max(x2, e.position.x), math.max(y2, e.position.y)
  end
  local feeds, takes = {}, {}
  for _, e in ipairs(c.surface.find_entities_filtered({ area = { { x1 - 4, y1 - 4 }, { x2 + 4, y2 + 4 } },
    type = { "inserter", "mining-drill" } })) do
    pcall(function()
      if e.type == "inserter" then
        if line_index(e.pickup_position) then
          takes[#takes + 1] = string.format("%s at (%.1f, %.1f)", e.name, e.position.x, e.position.y)
        end
      end
      if line_index(e.drop_position) then
        feeds[#feeds + 1] = string.format("%s at (%.1f, %.1f)", e.name, e.position.x, e.position.y)
      end
    end)
  end
  for idx, e in ipairs(line) do
    local prev = line[idx - 1]
    for _, s in ipairs(e.belt_neighbours.inputs or {}) do
      if not (prev and s == prev) and not line_index(s.position) then
        feeds[#feeds + 1] = string.format("side-load from the belt at (%.1f, %.1f)", s.position.x, s.position.y)
      end
    end
  end

  -- ends
  local first, last = line[1], line[#line]
  local start_note
  local up_main = first and next_up(first) or {}
  if #line >= MAX_TILES then start_note = "(traced " .. MAX_TILES .. " tiles; the line goes on)"
  elseif first and #up_main > 0 then start_note = "continues on unexplored ground"
  elseif first.type == "underground-belt" and first.belt_to_ground_type == "output" then
    start_note = string.format("starts at the underground %s at (%.1f, %.1f)", M.underground_note(first),
      first.position.x, first.position.y)
  else start_note = string.format("starts at (%.1f, %.1f): nothing feeds it from behind", first.position.x, first.position.y) end
  local end_note
  local outs = last and next_down(last) or {}
  if #outs == 0 then
    end_note = dead_end(c, last)
  elseif #line >= MAX_TILES then
    end_note = "(traced " .. MAX_TILES .. " tiles; the line goes on)"
  else
    local o = outs[1]
    if o and o.valid and o.direction ~= last.direction and IS_BELT[o.type] and not line_index(o.position) then
      end_note = string.format("side-loads onto the belt at (%.1f, %.1f) (items go onto its near lane)", o.position.x,
        o.position.y)
    else
      end_note = "continues on unexplored ground"
    end
  end

  return {
    start = pos(start), tiles = #line, legs = legs, begins = start_note, ends = end_note,
    fed_by = feeds, taken_by = takes, lane_capacity_per_min = math.floor(cap * 60 + 0.5),
  }
end

-- ------------------------------------------------------------ measure job

M.measure = {}

function M.measure.start(task)
  local c = companion.require_companion()
  local p = task.target
  if type(p) ~= "table" or type(p.x) ~= "number" or type(p.y) ~= "number" then error("measure_belt needs x and y") end
  vision.require_known(c.surface, c.force, p, "the belt there")
  local e = belt_at(c, p)
  if not e then error(string.format("no belt at (%.1f, %.1f)", p.x, p.y)) end
  local secs = math.max(2, math.min(tonumber(task.seconds) or 10, 120))
  task._m = { e = e, ends = game.tick + math.floor(secs * 60), secs = secs, seen = { {}, {} },
    count = { {}, {} }, last = nil, changed = false, samples = 0, stacked = 1 }
end

local function sample(m)
  local sig = {}
  local first = m.samples == 0 -- items already there at the start aren't arrivals
  for i = 1, 2 do
    for _, it in ipairs(m.e.get_transport_line(i).get_detailed_contents()) do
      sig[#sig + 1] = it.unique_id
      if not m.seen[i][it.unique_id] then
        m.seen[i][it.unique_id] = true
        if first then goto continue end
        local name = it.stack.name
        m.count[i][name] = (m.count[i][name] or 0) + it.stack.count
      end
      ::continue::
    end
  end
  table.sort(sig)
  local s = table.concat(sig, ",")
  if m.last and s ~= m.last then m.changed = true end
  m.last = s
  m.samples = m.samples + 1
end

function M.measure.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  local m = task._m
  if not (m.e and m.e.valid) then return { status = "failed", detail = "the belt was removed while measuring" } end
  if game.tick % 2 == 0 then sample(m) end
  if game.tick < m.ends then return nil end

  local e = m.e
  local cap = lane_capacity(e, c.force) * 60 -- items/min per lane
  local sides = SIDES[e.direction] or { "?", "?" }
  local parts, total = {}, 0
  for i = 1, 2 do
    local n, what = 0, {}
    for name, k in pairs(m.count[i]) do
      n = n + k
      what[#what + 1] = name
    end
    table.sort(what)
    local per_min = n * 60 / m.secs
    total = total + per_min
    parts[#parts + 1] = string.format("%s lane (%s side): %s%.0f/min (%d%% of %.0f)",
      i == 1 and "left" or "right", sides[i], #what > 0 and (table.concat(what, "+") .. " ") or "empty, ",
      per_min, cap > 0 and math.floor(100 * per_min / cap + 0.5) or 0, cap)
  end
  local _, now = lanes(e)
  local state
  if not m.changed and (now.left + now.right) > 0 then
    state = "NOT MOVING — the items on it stayed put the whole time (backed up: blocked or a dead end downstream)"
  elseif total == 0 then
    state = "empty — nothing passed"
  else
    state = "flowing"
  end
  return {
    status = "done",
    detail = string.format("belt at (%.1f, %.1f) moving %s, %gs: %s; total %.0f/min of %.0f (%d%%) — %s",
      e.position.x, e.position.y, DIR[e.direction] or "?", m.secs, table.concat(parts, "; "), total, 2 * cap,
      cap > 0 and math.floor(100 * total / (2 * cap) + 0.5) or 0, state),
  }
end

return M
