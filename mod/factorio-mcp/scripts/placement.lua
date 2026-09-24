-- Why can_place_entity said no, as specifically as we can tell. Shared by
-- can_place (spatial.lua), place (actions/build.lua) and build_plan.
local M = {}

-- The prototype's collision box at `pos`; quarter turns swap the axes.
function M.footprint(proto, pos, direction)
  local box = proto.collision_box
  local lt, rb = box.left_top, box.right_bottom
  local d = math.floor(tonumber(direction) or 0) % 16
  if d == 4 or d == 12 then
    lt, rb = { x = lt.y, y = lt.x }, { x = rb.y, y = rb.x }
  end
  return { { pos.x + lt.x, pos.y + lt.y }, { pos.x + rb.x, pos.y + rb.y } }
end

-- Snap a requested position onto the tile grid the way the game aligns the
-- entity: odd sizes sit on tile centres (x.5), even sizes on tile corners.
-- (92, -12) for a 1x1 belt means tile (92, -12), i.e. (92.5, -11.5).
-- Aligned positions are unchanged.
function M.snap(proto, pos, direction)
  local w, h = 1, 1
  pcall(function() w, h = proto.tile_width or 1, proto.tile_height or 1 end)
  local d = math.floor(tonumber(direction) or 0) % 16
  if d == 4 or d == 12 then w, h = h, w end
  local function s(v, n)
    if n % 2 == 1 then return math.floor(v) + 0.5 end
    return math.floor(v + 0.5)
  end
  return { x = s(pos.x, w), y = s(pos.y, h) }
end

-- Does the character stand inside this footprint? (Its own collision box is
-- about 0.4 x 0.4 tiles.)
function M.character_inside(c, area)
  local p, r = c.position, 0.25
  return p.x + r > area[1][1] and p.x - r < area[2][1] and p.y + r > area[1][2] and p.y - r < area[2][2]
end

-- Our own building standing in the footprint (placing there would
-- fast-replace it: the engine destroys it, contents and all). Returns the
-- entity and how many items it holds, or nil.
local IGNORE = { character = true, ["entity-ghost"] = true, ["tile-ghost"] = true, ["item-entity"] = true,
  ["item-request-proxy"] = true, resource = true, corpse = true, ["character-corpse"] = true }
function M.occupant(c, entity_name, pos, direction)
  local proto = prototypes.entity[entity_name]
  if not proto then return nil end
  local a = M.footprint(proto, pos, direction)
  local area = { { a[1][1] + 0.05, a[1][2] + 0.05 }, { a[2][1] - 0.05, a[2][2] - 0.05 } }
  for _, e in ipairs(c.surface.find_entities_filtered({ area = area, force = c.force })) do
    if e.valid and not IGNORE[e.type] then
      local n = 0
      pcall(function()
        for i = 1, e.get_max_inventory_index() do
          local inv = e.get_inventory(i)
          if inv then n = n + inv.get_item_count() end
        end
      end)
      return e, n
    end
  end
  return nil
end

-- Directions: most buildings face only north/east/south/west; a diagonal
-- value (e.g. 6) used to snap silently to a quarter turn.
function M.check_direction(entity_name, direction)
  local d = math.floor(tonumber(direction) or 0) % 16
  if d % 4 == 0 then return nil end
  local proto = prototypes.entity[entity_name]
  local flags = proto and proto.flags or {}
  local eight = flags["building-direction-8-way"] or flags["building-direction-16-way"]
  if eight and (d % 2 == 0 or flags["building-direction-16-way"]) then return nil end
  return string.format("direction %d is diagonal, but a %s can only face 0 (north), 4 (east), 8 (south) or 12 (west)",
    d, entity_name)
end

local function is_water(surface, x, y)
  local ok, res = pcall(function()
    return surface.get_tile(math.floor(x), math.floor(y)).collides_with("water_tile")
  end)
  return ok and res == true
end

local function touches_water(surface, area)
  for ty = math.floor(area[1][2]), math.max(math.ceil(area[2][2]) - 1, math.floor(area[1][2])) do
    for tx = math.floor(area[1][1]), math.max(math.ceil(area[2][1]) - 1, math.floor(area[1][1])) do
      if is_water(surface, tx, ty) then return true end
    end
  end
  return false
end

-- Resources a drill at pos could mine (matching its resource categories).
local function minable_under_drill(surface, proto, pos)
  local radius = 0
  pcall(function() radius = proto.get_mining_drill_radius() end)
  if radius <= 0 then return nil end
  local cats = {}
  pcall(function() cats = proto.resource_categories or {} end)
  local n = 0
  for _, r in ipairs(surface.find_entities_filtered({
    area = { { pos.x - radius, pos.y - radius }, { pos.x + radius, pos.y + radius } },
    type = "resource",
  })) do
    local cat = nil
    pcall(function() cat = r.prototype.resource_category end)
    if cat == nil or cats[cat] then n = n + 1 end
  end
  return n, radius
end

function M.explain(c, entity_name, pos, direction)
  local surface = c.surface
  local proto = prototypes.entity[entity_name]
  if not proto then return "no entity called '" .. tostring(entity_name) .. "'" end
  local area = M.footprint(proto, pos, direction)

  local blocker, me = nil, false
  for _, e in ipairs(surface.find_entities_filtered({ area = area })) do
    if e.valid then
      if e == c then
        me = true
      elseif e.type ~= "resource" and e.type ~= "item-entity" and not blocker then
        blocker = e
      end
    end
  end
  if blocker then
    return string.format("blocked by %s at (%.1f, %.1f)", blocker.name, blocker.position.x, blocker.position.y)
      .. (me and "; your character is standing in the footprint too" or "")
  end
  if proto.type == "offshore-pump" then
    -- Its footprint is meant to reach over water, so the generic water
    -- message would mislead. Say which directions would work here.
    local ok_dirs = {}
    for _, d in ipairs({ 0, 4, 8, 12 }) do
      local fits = false
      pcall(function()
        fits = surface.can_place_entity({ name = entity_name, position = pos, direction = d, force = c.force,
          build_check_type = defines.build_check_type.manual })
      end)
      if fits then ok_dirs[#ok_dirs + 1] = ({ [0] = "north (0)", [4] = "east (4)", [8] = "south (8)", [12] = "west (12)" })[d] end
    end
    if #ok_dirs > 0 then
      return "an offshore pump fits here only facing " .. table.concat(ok_dirs, " or ")
    end
    return "an offshore pump needs a shore spot: land tiles behind it and water under its intake, "
      .. "in some direction — none of the 4 directions fits here; move along the shore"
  end
  if touches_water(surface, area) then
    return "the footprint touches water"
  end
  if proto.type == "mining-drill" then
    local n, radius = minable_under_drill(surface, proto, pos)
    if n == 0 then
      local side = math.floor(radius * 2 + 0.5)
      return string.format("no resource this drill can mine under its %gx%g mining area at (%.1f, %.1f)",
        side, side, pos.x, pos.y)
    end
  end
  if me then
    return "your character is standing in the footprint"
  end
  -- Name what is in the way: an entity whose edge overlaps the footprint
  -- (found just outside it), else the tiles under it.
  local grown = { { area[1][1] - 0.3, area[1][2] - 0.3 }, { area[2][1] + 0.3, area[2][2] + 0.3 } }
  local near, nd
  local cx, cy = (area[1][1] + area[2][1]) / 2, (area[1][2] + area[2][2]) / 2
  for _, e in ipairs(surface.find_entities_filtered({ area = grown })) do
    if e.valid and e ~= c and e.type ~= "resource" and e.type ~= "item-entity" then
      local d = (e.position.x - cx) ^ 2 + (e.position.y - cy) ^ 2
      if not nd or d < nd then near, nd = e, d end
    end
  end
  if near then
    return string.format("the %s at (%.1f, %.1f) overlaps the footprint's edge — move it or place one tile over",
      near.name, near.position.x, near.position.y)
  end
  local tiles, seen = {}, {}
  pcall(function()
    for _, t in ipairs(surface.find_tiles_filtered({ area = area })) do
      if not seen[t.name] then seen[t.name] = true tiles[#tiles + 1] = t.name end
    end
  end)
  return "blocked by the ground here (tiles: " .. (#tiles > 0 and table.concat(tiles, ", ") or "unknown")
    .. ") — this tile type may not allow building, or the spot is outside the map"
end

return M
