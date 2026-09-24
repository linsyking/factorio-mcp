-- Combat visibility: the game's alert panel (read through any connected
-- player of our force — in 2.0 alerts live on players, and the panel is
-- force-wide information the human player already watches) and a battlefield
-- snapshot (damaged force entities, turrets without ammo, enemy clusters on
-- charted ground with the distance to our nearest entity, recent combat
-- events from the event log).
local companion = require("scripts.companion")
local events = require("scripts.events")
local vision = require("scripts.vision")

local M = {}

local MAX_DAMAGED = 30
local MAX_CLUSTERS = 10
local MAX_PER_CLUSTER_NAMED = 4
local CLUSTER_CELL = 8 -- grid cell size in tiles; 8-neighbour cells merge
local NEAREST_RADIUS = 120

local function round1(v)
  return math.floor(v * 2 + 0.5) / 2
end

local function distance(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return math.sqrt(dx * dx + dy * dy)
end

-- The alert panel: get_alerts returns { [surface index] -> { [alert type] ->
-- array of {tick, target?, prototype?, position?} } }.
function M.alerts(params)
  local c = companion.require_companion()
  local force, surface = c.force, c.surface
  local out = { surface = surface.name, tick = game.tick, groups = {} }

  local panel, pname = nil, nil
  for _, p in ipairs(game.connected_players) do
    if p.force == force then
      pname = p.name
      local ok, by_surface = pcall(function() return p.get_alerts({}) end)
      if ok and type(by_surface) == "table" then panel = by_surface end
      break
    end
  end
  if not panel then
    out.note = pname and ("player " .. pname .. " exposes no alert read")
      or "no connected player on this force — in 2.0 the alert panel lives on players; battle_report covers the same ground headless"
    return out
  end

  local by_type = panel[surface.index]
  if not by_type then return out end
  local names = {}
  for name, value in pairs(defines.alert_type) do names[value] = name end
  local groups = {}
  for type_id, alerts in pairs(by_type) do
    local entries = {}
    for _, a in ipairs(alerts) do
      local name, pos = "?", a.position
      if a.target and a.target.valid then
        name = a.target.name
        pos = a.target.position or pos
      elseif a.prototype then
        name = a.prototype.name
      end
      entries[#entries + 1] = {
        name = name,
        x = pos and round1(pos.x) or nil,
        y = pos and round1(pos.y) or nil,
        tick = a.tick,
      }
    end
    table.sort(entries, function(x, y) return x.tick < y.tick end)
    groups[#groups + 1] = { type = names[type_id] or tostring(type_id), count = #entries, alerts = entries }
  end
  table.sort(groups, function(a, b) return a.count > b.count end)
  out.groups = groups
  return out
end

-- Group enemy entities into position clusters: bucket into CLUSTER_CELL
-- grid cells, then flood-fill 8-neighbour cells into one cluster.
local function cluster_enemies(entities)
  local cells = {}
  for _, e in ipairs(entities) do
    if e.valid then
      local cx = math.floor(e.position.x / CLUSTER_CELL)
      local cy = math.floor(e.position.y / CLUSTER_CELL)
      local key = cx .. "," .. cy
      local cell = cells[key]
      if not cell then
        cell = { cx = cx, cy = cy, count = 0, sx = 0, sy = 0, by_name = {}, types = {} }
        cells[key] = cell
      end
      cell.count = cell.count + 1
      cell.sx = cell.sx + e.position.x
      cell.sy = cell.sy + e.position.y
      cell.by_name[e.name] = (cell.by_name[e.name] or 0) + 1
      cell.types[e.type] = (cell.types[e.type] or 0) + 1
    end
  end
  local clusters = {}
  for key, cell in pairs(cells) do
    if not cell.seen then
      cell.seen = true
      local stack = { cell }
      local count, sx, sy, by_name, types = 0, 0, 0, {}, {}
      while #stack > 0 do
        local cl = table.remove(stack)
        count = count + cl.count
        sx = sx + cl.sx
        sy = sy + cl.sy
        for n, k in pairs(cl.by_name) do by_name[n] = (by_name[n] or 0) + k end
        for n, k in pairs(cl.types) do types[n] = (types[n] or 0) + k end
        for dx = -1, 1 do
          for dy = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
              local nc = cells[(cl.cx + dx) .. "," .. (cl.cy + dy)]
              if nc and not nc.seen then
                nc.seen = true
                stack[#stack + 1] = nc
              end
            end
          end
        end
      end
      clusters[#clusters + 1] = {
        count = count,
        center = { x = round1(sx / count), y = round1(sy / count) },
        by_name = by_name,
        types = types,
      }
    end
  end
  return clusters
end

function M.report(params)
  local c = companion.require_companion()
  local surface, force = c.surface, c.force
  local out = { surface = surface.name, tick = game.tick }

  -- damage layer: our entities below max health (combat/collision damage —
  -- healthy machines never lose health)
  local damaged = {}
  for _, e in ipairs(surface.find_entities_filtered({ force = force })) do
    local ok, hp, max_hp = pcall(function() return e.health, e.max_health end)
    if ok and hp and max_hp and max_hp > 0 and hp < max_hp then
      damaged[#damaged + 1] = {
        name = e.name,
        x = round1(e.position.x),
        y = round1(e.position.y),
        hp = math.floor(hp + 0.5),
        max_hp = math.floor(max_hp + 0.5),
        pct = math.floor(hp / max_hp * 100 + 0.5),
      }
    end
  end
  table.sort(damaged, function(a, b) return a.pct < b.pct end)
  while #damaged > MAX_DAMAGED do table.remove(damaged) end
  if #damaged > 0 then out.damaged = damaged end

  -- turrets with an empty ammo inventory (the turret-out-of-ammo alert)
  local dry = {}
  for _, e in ipairs(surface.find_entities_filtered({ force = force, type = "turret" })) do
    local ok, inv = pcall(e.get_inventory, defines.inventory.turret_ammo)
    if ok and inv then
      local ok2, empty = pcall(function() return inv.is_empty() end)
      if ok2 and empty then
        dry[#dry + 1] = { name = e.name, x = round1(e.position.x), y = round1(e.position.y) }
      end
    end
  end
  if #dry > 0 then out.turrets_no_ammo = dry end

  -- enemy clusters on charted ground (the map rule: own-force vision)
  local enemies = vision.filter_known(
    surface.find_entities_filtered({ force = game.forces.enemy }), surface, force)
  local clusters = cluster_enemies(enemies)
  for _, cl in ipairs(clusters) do
    local best, best_d = nil, nil
    for _, e in ipairs(surface.find_entities_filtered({
      position = { x = cl.center.x, y = cl.center.y }, radius = NEAREST_RADIUS, force = force,
    })) do
      local d = distance(cl.center.x, cl.center.y, e.position.x, e.position.y)
      if not best_d or d < best_d then best_d, best = d, e.name end
    end
    cl.nearest = best and { name = best, distance = math.floor(best_d + 0.5) } or nil
  end
  table.sort(clusters, function(a, b)
    local da = a.nearest and a.nearest.distance or math.huge
    local db = b.nearest and b.nearest.distance or math.huge
    return da < db
  end)
  while #clusters > MAX_CLUSTERS do table.remove(clusters) end
  if #clusters > 0 then
    for _, cl in ipairs(clusters) do
      local names = {}
      for n in pairs(cl.by_name) do names[#names + 1] = n end
      table.sort(names, function(a, b) return cl.by_name[a] > cl.by_name[b] end)
      cl.top_names = {}
      for i = 1, math.min(#names, MAX_PER_CLUSTER_NAMED) do
        cl.top_names[i] = string.format("%dx %s", cl.by_name[names[i]], names[i])
      end
    end
    out.enemy_clusters = clusters
  end

  -- recent combat evidence from the event log (reading never consumes)
  local recent = events.recent(math.min(tonumber(params and params.recent_s) or 60, 600) * 60)
  while #recent > 0 and #recent > 15 do table.remove(recent, 1) end
  if #recent > 0 then out.recent = recent end

  return out
end

return M
