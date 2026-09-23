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
  if proto.type == "offshore-pump" then
    return "an offshore pump must stand on the shore with its intake over water"
  end
  if me then
    return "your character is standing in the footprint"
  end
  return "blocked (terrain, tile restrictions or an entity edge overlapping the footprint)"
end

return M
