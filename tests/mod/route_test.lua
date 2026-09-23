-- Offline tests for scripts/route/core.lua on ASCII grids.
-- Run: lua tests/mod/route_test.lua
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path
local core = require("scripts.route.core")

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

-- Legend: . free   # blocked   T tree (soft)   x inserter/drill tile (touch)
--         > < ^ v  foreign belt facing east/west/north/south (occupies, feeds next tile)
--         u foreign underground-belt   p foreign pipe (connects to 4 neighbours)
--         S start  G goal
local DIRS = { [">"] = 1, ["<"] = 3, ["^"] = 0, ["v"] = 2 }
local function grid(rows)
  local g = { H = #rows, W = #rows[1], blocked = {}, soft = {}, feed = {}, touch = {}, belt = {}, ug = {}, fluid_src = {} }
  local S, G
  for y, row in ipairs(rows) do
    for x = 1, #row do
      local ch = row:sub(x, x)
      local i = (y - 1) * g.W + (x - 1)
      if ch == "#" then g.blocked[i] = true
      elseif ch == "T" then g.soft[i] = true
      elseif ch == "x" then g.touch[i] = true
      elseif DIRS[ch] then
        g.belt[i] = true
        local n = core.neighbour(g, i, DIRS[ch])
        if n then g.feed[n] = true end
      elseif ch == "u" then g.belt[i] = true; g.ug[i] = "underground-belt"
      elseif ch == "p" then
        g.blocked[i] = true
        for d = 0, 3 do
          local n = core.neighbour(g, i, d)
          if n then g.fluid_src[n] = g.fluid_src[n] or {}; table.insert(g.fluid_src[n], i) end
        end
      elseif ch == "S" then S = i
      elseif ch == "G" then G = i end
    end
  end
  return g, S, G
end

local function route(rows, extra)
  local g, S, G = grid(rows)
  local opts = { kind = "belt", starts = { { tile = S } }, goal_tiles = { [G] = true }, endpoint = { [S] = true, [G] = true },
    allow_ug = true, ug_name = "underground-belt", ug_max = 5 }
  for k, v in pairs(extra or {}) do opts[k] = v end
  if opts.kind == "pipe" then opts.ug_name = "pipe-to-ground"; opts.ug_max = extra.ug_max or 10 end
  local path, stats = core.search(g, opts)
  local pl = path and core.placements(g, path, opts.kind)
  return pl, stats, g
end

local function count(pl, kind)
  local n = 0
  for _, p in ipairs(pl or {}) do if p.kind == kind then n = n + 1 end end
  return n
end

-- 1. straight
do
  local pl = route({ "S.....G" })
  check(pl and #pl == 7 and count(pl, "belt") == 7, "straight: 7 belts")
  check(pl and pl[1].d == 1 and pl[7].d == 1, "straight: all facing east")
end

-- 2. around a wall (undergrounds off)
do
  local pl, _, g = route({
    "..........",
    "S...#....G",
    "....#.....",
    "....#.....",
  }, { allow_ug = false })
  check(pl ~= nil, "wall: routed around without undergrounds")
  check(pl and core.validate_belts(g, pl, 5, "underground-belt") == nil, "wall: validator accepts")
end

-- 3. underground through a solid wall; the wall thickness limit follows the tier's reach
do
  local wall4 = { "S..####..G" }
  local pl = route(wall4)
  check(pl and count(pl, "ug") == 2, "underground: a 4-thick wall is tunnelled (1 pair)")
  local wall5 = { "S..#####..G" }
  check(route(wall5) == nil, "underground: a 5-thick wall is too far for max_distance 5")
  check(route(wall5, { ug_max = 7 }) ~= nil, "underground: fast belts (max 7) get through a 5-thick wall")
  check(route(wall4, { allow_ug = false }) == nil, "underground: disabled -> no route through the wall")
  if pl then
    local ent, ex = pl[3], pl[4]
    check(ent.ug_type == "input" and ex.ug_type == "output" and ent.d == 1 and ex.d == 1,
      "underground: entrance(input) then exit(output), both facing east")
  end
end

-- 4. crossing a foreign belt line: never feed into it, tunnel under it
do
  local pl = route({
    "....v....",
    "S...v...G",
    "....v....",
  }, { allow_ug = true })
  check(pl ~= nil and count(pl, "ug") == 2, "crossing: tunnels under a foreign belt line")
  local ok = true
  local g = grid({ "....v....", "S...v...G", "....v...." })
  for _, p in ipairs(pl or {}) do if g.belt[p.tile] or g.feed[p.tile] then ok = false end end
  check(ok, "crossing: no placement on or fed by the foreign belt")
end

-- 5. inserter / drill tiles are avoided
do
  local pl, _, g = route({ "S.xxx.G", "......." }, { allow_ug = false })
  local ok = pl ~= nil
  for _, p in ipairs(pl or {}) do if g.touch[p.tile] then ok = false end end
  check(ok, "touch: path avoids inserter/drill tiles")
end

-- 6. goal direction constraint
do
  local g, S, G = grid({ "S....", ".....", "....G" })
  local path = core.search(g, { kind = "belt", starts = { { tile = S } }, goal_tiles = { [G] = true },
    goal_dirs = { [G] = { [2] = true } }, endpoint = {}, allow_ug = false })
  local pl = path and core.placements(g, path, "belt")
  check(pl and pl[#pl].d == 2, "goal direction: last belt faces south as required")
end

-- 7. validator catches a belt feeding a non-successor
do
  local g = grid({ "......", "......" })
  local W = g.W
  -- east, east, south, west, north : the last belt points into the first
  local pl = {
    { kind = "belt", tile = 0, d = 1, state = 1 }, { kind = "belt", tile = 1, d = 1, state = 5 },
    { kind = "belt", tile = 2, d = 2, state = 10 }, { kind = "belt", tile = W + 2, d = 3, state = (W + 2) * 4 + 3 },
    { kind = "belt", tile = W + 1, d = 0, state = (W + 1) * 4 },
  }
  local bad = core.validate_belts(g, pl, 5, "underground-belt")
  check(bad ~= nil, "validator: a loop that feeds an earlier belt is rejected")
end

-- 8. pipes keep away from foreign pipes (or pass them underground)
do
  local pl, _, g = route({
    "..........",
    "..........",
    "S...p....G",
    "..........",
    "..........",
  }, { kind = "pipe", allow_ug = false })
  local ok = pl ~= nil
  for _, p in ipairs(pl or {}) do if g.fluid_src[p.tile] then ok = false end end
  check(ok, "pipes: never next to a foreign pipe")
  local plu = route({ "S.#######.G" }, { kind = "pipe", allow_ug = true, ug_max = 10 })
  check(plu and count(plu, "ptg") == 2, "pipes: pipe-to-ground pair through a 7-thick wall")
  if plu then
    local a, b
    for _, p in ipairs(plu) do if p.kind == "ptg" then if not a then a = p else b = p end end end
    check(a.d == 3 and b.d == 1, "pipes: entrance connects back (west), exit connects forward (east)")
  end
end

-- 9. trees cost extra but are usable (soft)
do
  local pl = route({ "S.TTT.G", "#######" }, { allow_ug = false })
  check(pl ~= nil and #pl == 7, "soft: goes through trees when that's the only way")
end

-- 10. performance: 150x150, 25% blocked, corner to corner
do
  math.randomseed(7)
  local rows = {}
  for y = 1, 150 do
    local r = {}
    for x = 1, 150 do r[x] = (math.random() < 0.25) and "#" or "." end
    rows[y] = table.concat(r)
  end
  rows[1] = "S" .. rows[1]:sub(2)
  rows[150] = rows[150]:sub(1, 149) .. "G"
  local t = os.clock()
  local pl, stats = route(rows)
  local dt = os.clock() - t
  print(string.format("     150x150 random: %s, %d expansions, %.0f ms", pl and (#pl .. " placements") or "no path",
    stats.expansions, dt * 1000))
  check(pl ~= nil and dt < 2.0, "performance: finds a route on a 150x150 grid in < 2 s")
end

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
