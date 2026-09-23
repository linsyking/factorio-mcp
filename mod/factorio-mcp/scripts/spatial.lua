-- Spatial perception (introduced in protocol v3): scan_area (ASCII tile grid), can_place
-- (dry-run placement check with blocker naming), find_buildable_area (nearest
-- clear rectangle) and describe_prototype (geometry/energy facts about items,
-- entities and recipes). All instant methods — no tasks, no side effects.
local companion = require("scripts.companion")
local vision = require("scripts.vision")
local placement = require("scripts.placement")

local M = {}

local SCAN_DEFAULT_RADIUS = 15
local SCAN_MIN_RADIUS = 5
local SCAN_MAX_RADIUS = 30
local AREA_DEFAULT_DISTANCE = 50
local AREA_MAX_DISTANCE = 100
local AREA_MAX_SIDE = 100
local AREA_RING_STEP = 2
local DESCRIBE_MAX_NAMES = 10

local UPPER_LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local LOWER_LETTERS = "abcdefghijklmnopqrstuvwxyz"

-- ---------------------------------------------------------------- helpers

local function require_position(pos, message)
  if type(pos) ~= "table" or tonumber(pos.x) == nil or tonumber(pos.y) == nil then
    error(message)
  end
  return { x = tonumber(pos.x), y = tonumber(pos.y) }
end

-- Water test for one tile. 2.0 names the collision layer "water_tile"; we
-- probe once per session (falling back to the hyphenated spelling, then to
-- reading the prototype collision mask directly) so a rename never breaks us.
local water_layer -- nil = not probed yet, false = probing failed, string = layer id

local function tile_is_water(tile)
  if water_layer then
    local ok, res = pcall(function() return tile.collides_with(water_layer) end)
    if ok then return res == true end
  end
  if water_layer == nil then
    for _, layer in ipairs({ "water_tile", "water-tile" }) do
      local ok, res = pcall(function() return tile.collides_with(layer) end)
      if ok then
        water_layer = layer
        return res == true
      end
    end
    water_layer = false
  end
  local ok, mask = pcall(function() return tile.prototype.collision_mask end)
  if ok and type(mask) == "table" and type(mask.layers) == "table" then
    return mask.layers["water_tile"] == true or mask.layers["water-tile"] == true
  end
  return false
end

local function is_water_at(surface, x, y)
  local ok, tile = pcall(surface.get_tile, x, y)
  if not ok or not tile then return false end
  return tile_is_water(tile)
end

-- Normalize a Factorio Vector ({x=,y=} or {1,2}) to a plain {x, y} table.
local function vec_xy(v)
  if type(v) ~= "table" then return nil end
  local x = tonumber(v.x) or tonumber(v[1])
  local y = tonumber(v.y) or tonumber(v[2])
  if x == nil or y == nil then return nil end
  return { x = x, y = y }
end

-- Sorted list of the keys of a {name = true} dictionary (nil when empty).
local function sorted_keys(dict)
  if type(dict) ~= "table" then return nil end
  local keys = {}
  for k in pairs(dict) do keys[#keys + 1] = k end
  if #keys == 0 then return nil end
  table.sort(keys)
  return keys
end

-- --------------------------------------------------------------- scan_area

-- Higher paints over lower when several things share a tile.
local PRIORITY = {
  land = 0, water = 1, cliff = 2, rock = 3, tree = 4,
  resource = 5, building = 6, enemy = 7, player = 8, companion = 9,
}

function M.scan_area(params)
  local c = companion.require_companion()
  local surface = c.surface

  local radius = math.floor(tonumber(params.radius) or SCAN_DEFAULT_RADIUS)
  radius = math.max(SCAN_MIN_RADIUS, math.min(radius, SCAN_MAX_RADIUS))

  local center = c.position
  if params.center ~= nil then
    center = require_position(params.center, "scan_area center must be {x, y}")
  end

  local ox = math.floor(center.x) - radius
  local oy = math.floor(center.y) - radius
  local size = radius * 2 + 1

  -- Fixed symbols are pre-registered so dynamically assigned letters can
  -- never collide with them (T/R/E/P and lowercase c are reserved).
  local legend = {
    ["?"] = "unexplored (fog of war)",
    ["."] = "buildable land",
    ["~"] = "water",
    ["c"] = "cliff",
    ["T"] = "tree",
    ["R"] = "rock",
    ["@"] = "you",
    ["P"] = "player or another agent character",
    ["E"] = "enemy",
  }

  -- Letters are remembered per character, so the same building/resource
  -- keeps its symbol across scans (storage.scan_letters[character][name]).
  storage.scan_letters = storage.scan_letters or {}
  local mine = storage.scan_letters[companion.context()] or {}
  storage.scan_letters[companion.context()] = mine
  local taken = {}
  for n, ch in pairs(mine) do taken[ch] = n end
  local function letter_for(name, alphabet)
    local ch = mine[name]
    if not ch then
      for i = 1, #alphabet do
        local cand = string.sub(alphabet, i, i)
        if legend[cand] == nil and taken[cand] == nil then
          ch = cand
          break
        end
      end
      if not ch then
        legend["*"] = "several different things (ran out of letters)"
        return "*"
      end
      mine[name] = ch
      taken[ch] = name
    end
    legend[ch] = name
    return ch
  end

  -- Terrain pass: unexplored / land / water. Unexplored tiles stay "?" —
  -- nothing paints over them (fog of war, see scripts/vision.lua).
  local known_memo = {}
  local function known_tile(x, y)
    local k = math.floor(x / 32) .. "," .. math.floor(y / 32)
    local v = known_memo[k]
    if v == nil then
      v = vision.is_known(surface, c.force, { x = x, y = y })
      known_memo[k] = v
    end
    return v
  end
  local UNKNOWN = 1000
  local chars, prio = {}, {}
  for row = 1, size do
    local crow, prow = {}, {}
    chars[row], prio[row] = crow, prow
    for col = 1, size do
      if not known_tile(ox + col - 1, oy + row - 1) then
        crow[col], prow[col] = "?", UNKNOWN
      elseif is_water_at(surface, ox + col - 1, oy + row - 1) then
        crow[col], prow[col] = "~", PRIORITY.water
      else
        crow[col], prow[col] = ".", PRIORITY.land
      end
    end
  end

  -- Entity pass: one scan over the whole box. Buildings paint every tile of
  -- their footprint; everything else paints its center tile.
  local enemy_force = game.forces.enemy
  local entities = vision.filter_perceivable(surface.find_entities_filtered({
    area = { { ox, oy }, { ox + size, oy + size } },
  }), surface, c.force)
  for _, e in ipairs(entities) do
    if e.valid then
        local ch, p
        local footprint = false
        if e == c then
          ch, p = "@", PRIORITY.companion
        elseif e.type == "character" then
          ch, p = "P", PRIORITY.player
        elseif e.force == enemy_force then
          ch, p = "E", PRIORITY.enemy
        elseif e.force == c.force then
          ch, p = letter_for(e.name, LOWER_LETTERS), PRIORITY.building
          footprint = true
        elseif e.type == "resource" then
          ch, p = letter_for(e.name, UPPER_LETTERS), PRIORITY.resource
        elseif e.type == "tree" then
          ch, p = "T", PRIORITY.tree
        elseif e.type == "simple-entity" then
          ch, p = "R", PRIORITY.rock
        elseif e.type == "cliff" then
          ch, p = "c", PRIORITY.cliff
        end
        if ch then
          local x1, y1, x2, y2 = e.position.x, e.position.y, e.position.x, e.position.y
          if footprint then
            local bb = e.bounding_box
            x1, y1 = bb.left_top.x + 0.01, bb.left_top.y + 0.01
            x2, y2 = bb.right_bottom.x - 0.01, bb.right_bottom.y - 0.01
          end
          for ty = math.floor(y1), math.floor(y2) do
            for tx = math.floor(x1), math.floor(x2) do
              local col, row = tx - ox + 1, ty - oy + 1
              if col >= 1 and col <= size and row >= 1 and row <= size and p > prio[row][col] then
                chars[row][col], prio[row][col] = ch, p
              end
            end
          end
        end
    end
  end

  local grid = {}
  for row = 1, size do
    grid[row] = table.concat(chars[row])
  end

  return {
    origin = { x = ox, y = oy },
    width = size,
    height = size,
    grid = grid,
    legend = legend,
    note = "tile at grid[row][col] = map (origin.x+col, origin.y+row); rows run north to south."
      .. " Your force's buildings cover their whole footprint; other entities mark their center tile."
      .. " Letters stay the same for you across scans.",
  }
end

-- --------------------------------------------------------------- can_place

local function can_place_one(c, surface, item, position, direction)
  if type(item) ~= "string" then
    error("can_place requires item = <item name>")
  end
  local pos = require_position(position, "can_place requires position = {x, y}")
  direction = math.floor(tonumber(direction) or 0) % 16
  vision.require_known(surface, c.force, pos, "whether it's free")

  local item_proto = prototypes.item[item]
  if not item_proto then
    error("no item called '" .. item .. "' — check the spelling with describe_prototype")
  end
  local entity_proto = item_proto.place_result
  if not entity_proto then
    error(item .. " is not a placeable item — it doesn't turn into a building")
  end

  local ok = surface.can_place_entity({
    name = entity_proto.name,
    position = pos,
    direction = direction,
    force = c.force,
    build_check_type = defines.build_check_type.manual,
  })
  if ok then
    return { can_place = true }
  end

  local reason = placement.explain(c, entity_proto.name, pos, direction)
  return { can_place = false, reason = reason }
end

local MAX_PLACEMENTS = 24

-- Single check ({item, position, direction}) or batched: placements =
-- [{item?, position = {x,y}, direction?}, ...] checks up to MAX_PLACEMENTS
-- spots in ONE call (item falls back to the top-level one). Spot-checking a
-- build one tile at a time costs the brain a full think per tile.
function M.can_place(params)
  local c = companion.require_companion()
  local surface = c.surface

  if type(params.placements) == "table" then
    if #params.placements == 0 then
      error("placements must be a non-empty array")
    end
    if #params.placements > MAX_PLACEMENTS then
      error("can_place takes at most " .. MAX_PLACEMENTS .. " placements per call — split the list")
    end
    local out = {}
    for i, p in ipairs(params.placements) do
      local ok, res = pcall(can_place_one, c, surface,
        p.item or params.item, p.position, p.direction)
      if not ok then
        res = { can_place = false, reason = tostring(res):gsub("^.-:%d+:%s*", "") }
      end
      res.position = {
        x = tonumber(type(p.position) == "table" and p.position.x or nil),
        y = tonumber(type(p.position) == "table" and p.position.y or nil),
      }
      out[i] = res
    end
    return { results = out }
  end

  return can_place_one(c, surface, params.item, params.position, params.direction)
end

-- ------------------------------------------------------- find_buildable_area

-- Offsets on the square ring of Chebyshev radius d, in AREA_RING_STEP steps.
local function ring_offsets(d)
  if d == 0 then return { { 0, 0 } } end
  local offsets = {}
  for x = -d, d, AREA_RING_STEP do
    offsets[#offsets + 1] = { x, -d }
    offsets[#offsets + 1] = { x, d }
  end
  for y = -d + AREA_RING_STEP, d - AREA_RING_STEP, AREA_RING_STEP do
    offsets[#offsets + 1] = { -d, y }
    offsets[#offsets + 1] = { d, y }
  end
  return offsets
end

function M.find_buildable_area(params)
  local c = companion.require_companion()
  local surface = c.surface

  local width = math.floor(tonumber(params.width) or 0)
  local height = math.floor(tonumber(params.height) or 0)
  if width < 1 or height < 1 then
    error("find_buildable_area requires width and height (whole tile counts, at least 1)")
  end
  if width > AREA_MAX_SIDE or height > AREA_MAX_SIDE then
    error(string.format(
      "that rectangle is huge — keep width and height at %d tiles or less", AREA_MAX_SIDE))
  end
  local near = require_position(params.near, "find_buildable_area requires near = {x, y}")
  local max_distance = math.floor(tonumber(params.max_distance) or AREA_DEFAULT_DISTANCE)
  max_distance = math.max(0, math.min(max_distance, AREA_MAX_DISTANCE))

  -- Candidate rectangles are centered on `near`, then shifted in expanding
  -- rings. Water is memoized per tile since neighboring candidates overlap.
  local base_x = math.floor(near.x) - math.floor(width / 2)
  local base_y = math.floor(near.y) - math.floor(height / 2)

  local water_memo = {}
  local function memo_water(x, y)
    local key = x .. "," .. y
    local v = water_memo[key]
    if v == nil then
      v = is_water_at(surface, x, y)
      water_memo[key] = v
    end
    return v
  end

  local known_memo = {}
  local function rect_known(tlx, tly)
    for cy = math.floor(tly / 32), math.floor((tly + height - 1) / 32) do
      for cx = math.floor(tlx / 32), math.floor((tlx + width - 1) / 32) do
        local k = cx .. "," .. cy
        local v = known_memo[k]
        if v == nil then
          v = vision.is_known(surface, c.force, { x = cx * 32, y = cy * 32 })
          known_memo[k] = v
        end
        if not v then return false end
      end
    end
    return true
  end

  -- Returns the tree count when the rect works, nil when it doesn't.
  -- Only explored ground counts (fog of war).
  local function try_spot(tlx, tly)
    if not rect_known(tlx, tly) then return nil end
    local trees = 0
    local found = surface.find_entities_filtered({
      area = { { tlx, tly }, { tlx + width, tly + height } },
    })
    for _, e in ipairs(found) do
      if e.valid and e ~= c then
        if e.type == "tree" then
          trees = trees + 1
        else
          return nil
        end
      end
    end
    for ty = tly, tly + height - 1 do
      for tx = tlx, tlx + width - 1 do
        if memo_water(tx, ty) then return nil end
      end
    end
    return trees
  end

  for d = 0, max_distance, AREA_RING_STEP do
    for _, off in ipairs(ring_offsets(d)) do
      local tlx, tly = base_x + off[1], base_y + off[2]
      local trees = try_spot(tlx, tly)
      if trees then
        return {
          center = { x = tlx + width / 2, y = tly + height / 2 },
          top_left = { x = tlx, y = tly },
          trees_in_area = trees,
        }
      end
    end
  end

  error(string.format(
    "no free %dx%d spot on explored ground within %d tiles of (%.0f, %.0f)",
    width, height, max_distance, near.x, near.y))
end

-- -------------------------------------------------------- describe_prototype

local function describe_entity(ent, item_name)
  local out = { kind = "entity", entity = ent.name, type = ent.type }

  if not item_name then
    -- Which item places this entity (nice to know when the caller asked by
    -- entity name).
    local ok, items = pcall(function() return ent.items_to_place_this end)
    if ok and type(items) == "table" and type(items[1]) == "table" and items[1].name then
      item_name = items[1].name
    end
  end
  if item_name then out.placed_by_item = item_name end

  local ok, v

  ok, v = pcall(function() return ent.tile_width end)
  if ok and type(v) == "number" then out.tile_width = v end
  ok, v = pcall(function() return ent.tile_height end)
  if ok and type(v) == "number" then out.tile_height = v end

  -- Mining drills: where the ore comes out, at direction 0 (rotate with the
  -- entity — 4:(x,y)->(-y,x), 8:(-x,-y), 12:(y,-x)).
  ok, v = pcall(function() return ent.vector_to_place_result end)
  if ok then
    local offset = vec_xy(v)
    if offset then out.drop_offset = offset end
  end

  local burner, electric
  ok, v = pcall(function() return ent.burner_prototype end)
  if ok then burner = v end
  ok, v = pcall(function() return ent.electric_energy_source_prototype end)
  if ok then electric = v end
  out.energy = (burner and "burner") or (electric and "electric") or "none"
  if burner then
    ok, v = pcall(function() return burner.fuel_categories end)
    if ok then out.fuel_categories = sorted_keys(v) end
  end

  ok, v = pcall(function() return ent.mining_speed end)
  if ok and type(v) == "number" then out.mining_speed = v end

  ok, v = pcall(function() return ent.crafting_categories end)
  if ok then out.crafting_categories = sorted_keys(v) end

  -- Gun range lives on the ITEM prototype; turrets carry theirs on the entity.
  if item_name then
    local it = prototypes.item[item_name]
    if it then
      ok, v = pcall(function() return it.attack_parameters end)
      if ok and type(v) == "table" and type(v.range) == "number" then out.range = v.range end
    end
  end
  if out.range == nil then
    ok, v = pcall(function() return ent.attack_parameters end)
    if ok and type(v) == "table" and type(v.range) == "number" then out.range = v.range end
  end

  ok, v = pcall(function() return ent.inserter_pickup_position end)
  if ok then
    local offset = vec_xy(v)
    if offset then out.inserter_pickup_offset = offset end
  end
  ok, v = pcall(function() return ent.inserter_drop_position end)
  if ok then
    local offset = vec_xy(v)
    if offset then out.inserter_drop_offset = offset end
  end

  ok, v = pcall(function() return ent.belt_speed end)
  if ok and type(v) == "number" then out.belt_speed = v end

  return out
end

local function describe_recipe(rec, force)
  local ingredients, products = {}, {}
  for _, ing in ipairs(rec.ingredients or {}) do
    if ing.name then
      ingredients[ing.name] = (ingredients[ing.name] or 0) + (ing.amount or 1)
    end
  end
  for _, p in ipairs(rec.products or {}) do
    if p.name then
      products[p.name] = (products[p.name] or 0) + (p.amount or p.amount_max or 1)
    end
  end
  local force_recipe = force.recipes[rec.name]
  return {
    name = rec.name,
    ingredients = ingredients,
    products = products,
    energy = rec.energy,
    category = rec.category,
    enabled = (force_recipe and force_recipe.enabled) or false,
  }
end

local function describe_item(it)
  local out = { name = it.name, stack_size = it.stack_size }
  local ok, v = pcall(function() return it.fuel_value end)
  if ok and type(v) == "number" and v > 0 then
    out.fuel_value_mj = v / 1e6
    pcall(function() out.fuel_category = it.fuel_category end)
  end
  pcall(function() if it.place_result then out.places = it.place_result.name end end)
  return out
end

-- Power/speed facts shared by every entity kind (J/tick -> kW = x * 60 / 1000).
local function energy_facts(ent, out)
  local ok, v = pcall(function() return ent.get_max_energy_usage() end)
  if ok and type(v) == "number" and v > 0 then out.power_kw = v * 60 / 1000 end
  ok, v = pcall(function() return ent.get_max_energy_production() end)
  if ok and type(v) == "number" and v > 0 then out.power_output_kw = v * 60 / 1000 end
  ok, v = pcall(function() return ent.get_crafting_speed() end)
  if ok and type(v) == "number" and v > 0 then out.crafting_speed = v end
  ok, v = pcall(function() return ent.get_mining_drill_radius() end)
  if ok and type(v) == "number" and v > 0 then out.mining_area = math.floor(2 * v + 0.5) end
  ok, v = pcall(function() return ent.resource_categories end)
  if ok and type(v) == "table" then out.resource_categories = sorted_keys(v) end
  ok, v = pcall(function() return ent.module_inventory_size end)
  if ok and type(v) == "number" and v > 0 then out.module_slots = v end
  ok, v = pcall(function() return ent.get_inserter_rotation_speed() end)
  if ok and type(v) == "number" and v > 0 then out.inserter_rotation_speed = v end
  ok, v = pcall(function() return ent.get_inventory_size(defines.inventory.chest) end)
  if ok and type(v) == "number" and v > 0 then out.inventory_slots = v end
  ok, v = pcall(function() return ent.get_researching_speed() end)
  if ok and type(v) == "number" and v > 0 then out.researching_speed = v end
end

-- Every view of a name at once: the item (stack size, fuel value), the
-- entity it places (geometry, power, speeds) and the recipe that makes it.
function M.describe_prototype(params)
  local names = params.names
  if type(names) ~= "table" or #names == 0 then
    error('describe_prototype requires names = ["burner-mining-drill", ...]')
  end
  if #names > DESCRIBE_MAX_NAMES then
    error(string.format(
      "describe_prototype takes at most %d names per call — split the list and call again",
      DESCRIBE_MAX_NAMES))
  end

  local c = companion.get()
  local force = (c and c.force) or game.forces.player

  local out = {}
  for _, name in ipairs(names) do
    if type(name) == "string" then
      local r = {}
      local item = prototypes.item[name]
      if item then r.item = describe_item(item) end
      local ent = (item and item.place_result) or prototypes.entity[name]
      if ent then
        r.entity = describe_entity(ent, item and item.place_result and name or nil)
        energy_facts(ent, r.entity)
      end
      if prototypes.recipe[name] then r.recipe = describe_recipe(prototypes.recipe[name], force) end
      local fluid = prototypes.fluid[name]
      if fluid then
        r.fluid = { name = name, default_temperature = fluid.default_temperature, max_temperature = fluid.max_temperature }
      end
      if next(r) == nil then r.unknown = true end
      out[name] = r
    end
  end
  return out
end

return M
