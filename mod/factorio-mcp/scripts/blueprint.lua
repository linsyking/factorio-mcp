-- Blueprint access. Ways in, one normalized format out:
--   import_blueprint  — decode an export string
--   list_blueprints   — enumerate the blueprints YOUR character carries
--                       (main inventory, books — nested books included)
--   read_blueprint    — decode one of those by label
--   export_blueprint  — capture an explored area of the map as a blueprint
--                       string (like a player's blueprint tool)
-- Huge prints are read in windows (offset/limit) sized for build_plan batches;
-- the item bill and footprint always cover the whole print. Other players'
-- inventories and cursors are not readable (a player couldn't read them).
local companion = require("scripts.companion")
local vision = require("scripts.vision")
local items = require("scripts.items")

local M = {}

local DEFAULT_WINDOW = 100 -- one build_plan batch
local MAX_WINDOW = 200
local MAX_LISTED = 200
local MAX_BOOK_DEPTH = 4
local MAX_LABELS_IN_ERROR = 40

local function try(fn)
  local ok, v = pcall(fn)
  if ok then return v end
  return nil
end

local function round1(v)
  return math.floor(v * 10 + 0.5) / 10
end

-- Normalize any holder exposing get_blueprint_entities() (LuaItemStack or
-- LuaRecord): every valid entity with its position RELATIVE to the print's
-- top-left entity, the item each one consumes (rails: the rail ITEM places
-- curved segments too, so the entity name travels separately), the whole
-- print's item bill, footprint and skipped (unknown) names.
local function normalize(holder)
  local ents = holder.get_blueprint_entities()
  if not ents or #ents == 0 then
    error("the blueprint is empty — no entities to build")
  end

  local min_x, min_y = math.huge, math.huge
  for _, e in ipairs(ents) do
    if prototypes.entity[e.name] then
      min_x = math.min(min_x, e.position.x)
      min_y = math.min(min_y, e.position.y)
    end
  end
  if min_x == math.huge then
    error("none of the blueprint's entities exist in this game (modded blueprint?)")
  end

  local list, needed, skipped_set = {}, {}, {}
  local max_x, max_y = 0, 0
  for _, e in ipairs(ents) do
    local proto = prototypes.entity[e.name]
    if not proto then
      skipped_set[e.name] = true
    else
      local pos = { x = round1(e.position.x - min_x), y = round1(e.position.y - min_y) }
      max_x = math.max(max_x, pos.x)
      max_y = math.max(max_y, pos.y)
      local place_items = try(function() return proto.items_to_place_this end)
      local item_name = (place_items and place_items[1] and place_items[1].name) or e.name
      local item_key = items.key(item_name, e.quality)
      needed[item_key] = (needed[item_key] or 0) + 1
      list[#list + 1] = {
        name = e.name,
        item = item_key,
        position = pos,
        direction = e.direction or 0,
        recipe = e.recipe,
        quality = (e.quality and e.quality ~= "normal") and e.quality or nil,
        underground_type = (proto.type == "underground-belt") and e.type or nil,
      }
    end
  end

  local skipped = {}
  for name in pairs(skipped_set) do
    skipped[#skipped + 1] = name
  end

  return {
    list = list,
    items_needed = needed,
    skipped = skipped,
    size = { w = math.ceil(max_x) + 1, h = math.ceil(max_y) + 1 },
  }
end

-- One WINDOW of entities (offset/limit) so huge prints are read in batches;
-- the origin never moves with the window, so every batch shares one anchor.
local function decode(holder, label, offset, limit)
  local norm = normalize(holder)
  local total = #norm.list

  offset = math.max(math.floor(tonumber(offset) or 0), 0)
  limit = math.floor(tonumber(limit) or DEFAULT_WINDOW)
  limit = math.max(1, math.min(limit, MAX_WINDOW))

  if offset >= total then
    error(string.format("offset %d is past the end — the blueprint has %d entities", offset, total))
  end

  local window = {}
  for i = offset + 1, math.min(offset + limit, total) do
    local e = norm.list[i]
    window[#window + 1] = {
      name = e.name,
      position = e.position,
      direction = e.direction,
      recipe = e.recipe,
      quality = e.quality,
    }
  end
  local needed, skipped = norm.items_needed, norm.skipped

  -- Flooring (concrete/landfill) the companion has no tool to place — report
  -- it so the brain knows the print expects prepared ground.
  local tiles
  local bp_tiles = try(function() return holder.get_blueprint_tiles() end)
  if bp_tiles and #bp_tiles > 0 then
    local kinds_set, kinds = {}, {}
    for _, t in ipairs(bp_tiles) do kinds_set[t.name] = true end
    for name in pairs(kinds_set) do kinds[#kinds + 1] = name end
    table.sort(kinds)
    tiles = { count = #bp_tiles, kinds = kinds }
  end

  local next_offset = offset + #window
  return {
    label = label,
    size = norm.size,
    total_entities = total,
    offset = offset,
    entities = window,
    next_offset = (next_offset < total) and next_offset or nil,
    items_needed = needed, -- whole print, not just this window
    skipped = (#skipped > 0) and skipped or nil,
    tiles = tiles,
  }
end

-- Decode an export string into a scratch inventory and run fn(stack).
local function with_imported(str, fn)
  if type(str) ~= "string" or #str < 10 then
    error("a blueprint export string is required (starts with 0eNq...)")
  end
  local inv = game.create_inventory(1)
  local ok, result = pcall(function()
    local stack = inv[1]
    -- import_stack: 0 = ok, -1 = ok with errors (modded content missing
    -- here — it still imports), 1 = failed outright.
    if stack.import_stack(str) == 1 or not stack.valid_for_read then
      error("that string isn't a valid blueprint export string")
    end
    if stack.is_blueprint_book then
      error("that's a blueprint BOOK — pass a single blueprint's string")
    end
    if not stack.is_blueprint then
      error("that string decodes to '" .. (try(function() return stack.name end) or "?")
        .. "', not a blueprint")
    end
    return fn(stack)
  end)
  pcall(function() inv.destroy() end)
  if not ok then error(result, 0) end
  return result
end

function M.import(params)
  return with_imported(params.string, function(stack)
    return decode(stack, try(function() return stack.label end), params.offset, params.limit)
  end)
end

-- export_blueprint {area = {{x1,y1},{x2,y2}}} or {center={x,y}, radius}:
-- capture the force's buildings in an explored area as an export string plus
-- the decoded summary (entity counts, footprint). Like the blueprint tool, it
-- only captures the force's own entities.
local EXPORT_MAX_SIDE = 200

function M.export(params)
  local c = companion.require_companion()
  local x1, y1, x2, y2
  if type(params.area) == "table" and type(params.area[1]) == "table" and type(params.area[2]) == "table" then
    x1, y1 = tonumber(params.area[1].x or params.area[1][1]), tonumber(params.area[1].y or params.area[1][2])
    x2, y2 = tonumber(params.area[2].x or params.area[2][1]), tonumber(params.area[2].y or params.area[2][2])
  elseif type(params.center) == "table" then
    local r = tonumber(params.radius) or 16
    x1, y1 = params.center.x - r, params.center.y - r
    x2, y2 = params.center.x + r, params.center.y + r
  end
  if not (x1 and y1 and x2 and y2) then
    error("export_blueprint needs area = {{x1,y1},{x2,y2}} or center = {x,y} with radius")
  end
  if x1 > x2 then x1, x2 = x2, x1 end
  if y1 > y2 then y1, y2 = y2, y1 end
  if x2 - x1 > EXPORT_MAX_SIDE or y2 - y1 > EXPORT_MAX_SIDE then
    error("export area is limited to " .. EXPORT_MAX_SIDE .. "x" .. EXPORT_MAX_SIDE .. " tiles")
  end
  for cy = math.floor(y1 / 32), math.floor(y2 / 32) do
    for cx = math.floor(x1 / 32), math.floor(x2 / 32) do
      vision.require_known(c.surface, c.force, { x = cx * 32 + 16, y = cy * 32 + 16 }, "what is built there")
    end
  end
  local inv = game.create_inventory(1)
  local ok, result = pcall(function()
    local stack = inv[1]
    stack.set_stack({ name = "blueprint" })
    stack.create_blueprint({
      surface = c.surface,
      force = c.force,
      area = { { x1, y1 }, { x2, y2 } },
      always_include_tiles = false,
      include_entities = true,
      include_modules = true,
      include_station_names = true,
      include_trains = false,
      include_fuel = false,
    })
    if (try(function() return stack.get_blueprint_entity_count() end) or 0) == 0 then
      error(string.format("no buildings of your force in (%.0f, %.0f)-(%.0f, %.0f)", x1, y1, x2, y2))
    end
    if type(params.label) == "string" and params.label ~= "" then stack.label = params.label end
    local norm = normalize(stack)
    local counts = {}
    for _, e in ipairs(norm.list) do counts[e.name] = (counts[e.name] or 0) + 1 end
    return {
      string = stack.export_stack(),
      entity_counts = counts,
      total_entities = #norm.list,
      size = norm.size,
      area = { left_top = { x = x1, y = y1 }, right_bottom = { x = x2, y = y2 } },
      -- where the print's top-left entity sits on the map (anchor for rebuilding in place)
      anchor = { x = x1, y = y1 },
    }
  end)
  pcall(function() inv.destroy() end)
  if not ok then error(result, 0) end
  return result
end

-- ------------------------------------------------------------ enumeration

-- Every blueprint the bound character carries, recursing into blueprint
-- books (books nest — a page can be another book, so track the full path).
local function collect_holders(params)
  local holders = {}
  local function add(holder, where, book, label)
    holders[#holders + 1] = { holder = holder, where = where, book = book, label = label }
  end

  local function scan_book(stack, where_prefix, path, depth)
    if depth > MAX_BOOK_DEPTH then return end
    local book_label = try(function() return stack.label end) or "unnamed book"
    local book_path = path and (path .. ' > "' .. book_label .. '"') or ('"' .. book_label .. '"')
    local book_inv = try(function() return stack.get_inventory(defines.inventory.item_main) end)
    if not book_inv then return end
    for j = 1, #book_inv do
      local page = book_inv[j]
      if page and page.valid_for_read then
        if page.is_blueprint then
          add(page, where_prefix .. " > book " .. book_path, book_path,
            try(function() return page.label end))
        elseif page.is_blueprint_book then
          scan_book(page, where_prefix, book_path, depth + 1)
        end
      end
    end
  end

  local function scan_inventory(inv, where_prefix)
    if not inv then return end
    for i = 1, #inv do
      local stack = inv[i]
      if stack and stack.valid_for_read then
        if stack.is_blueprint then
          add(stack, where_prefix, nil, try(function() return stack.label end))
        elseif stack.is_blueprint_book then
          scan_book(stack, where_prefix, nil, 1)
        end
      end
    end
  end

  local c = companion.require_companion()
  scan_inventory(c.get_main_inventory(), "your inventory")

  return holders
end

-- Cheap entity count: prefer the dedicated counter over decoding the print.
local function entity_count_of(holder)
  local n = try(function() return holder.get_blueprint_entity_count() end)
  if n then return n end
  return try(function()
    local ents = holder.get_blueprint_entities()
    return ents and #ents or 0
  end) or 0
end

-- Bounded label list for error messages.
local function label_list(holders)
  local names = {}
  for i, h in ipairs(holders) do
    if i > MAX_LABELS_IN_ERROR then
      names[#names + 1] = string.format("… and %d more", #holders - MAX_LABELS_IN_ERROR)
      break
    end
    names[#names + 1] = h.label or "(unnamed)"
  end
  return table.concat(names, ", ")
end

function M.list(params)
  local holders = collect_holders(params)
  local out = {}
  for i, h in ipairs(holders) do
    if i > MAX_LISTED then break end
    out[#out + 1] = {
      label = h.label,
      where = h.where,
      book = h.book,
      entity_count = entity_count_of(h.holder),
    }
  end
  return {
    blueprints = out,
    total = #holders,
    note = "only blueprints your character carries are listed; import_blueprint decodes export strings",
  }
end

-- Collect + filter (book) + match (label): the shared selection used by both
-- read_blueprint and the build_blueprint task.
local function choose_holder(params)
  local holders = collect_holders(params)
  if #holders == 0 then
    error("your character carries no blueprints — import_blueprint / build_blueprint take export strings")
  end

  -- Optional book filter first: disambiguates duplicate labels across books.
  if type(params.book) == "string" and params.book ~= "" then
    local wanted_book = params.book:lower()
    local filtered = {}
    for _, h in ipairs(holders) do
      if h.book and h.book:lower():find(wanted_book, 1, true) then
        filtered[#filtered + 1] = h
      end
    end
    if #filtered == 0 then
      local seen, books = {}, {}
      for _, h in ipairs(holders) do
        if h.book and not seen[h.book] then
          seen[h.book] = true
          books[#books + 1] = h.book
        end
      end
      error('no book matching "' .. params.book .. '" — available books: '
        .. (#books > 0 and table.concat(books, ", ") or "(none)"))
    end
    holders = filtered
  end

  local wanted = type(params.label) == "string" and params.label:lower() or nil
  if wanted then
    for _, h in ipairs(holders) do
      if h.label and h.label:lower() == wanted then return h end
    end
    for _, h in ipairs(holders) do
      if h.label and h.label:lower():find(wanted, 1, true) then return h end
    end
    error('no blueprint matching "' .. params.label .. '" — available: ' .. label_list(holders))
  end
  return holders[1]
end

function M.read(params)
  local chosen = choose_holder(params)
  local result = decode(chosen.holder, chosen.label, params.offset, params.limit)
  result.where = chosen.where
  result.book = chosen.book
  return result
end

-- Everything the build_blueprint task needs: the FULL print (no window),
-- positions still relative to the top-left entity, item + entity name per
-- step. See scripts/actions/build_blueprint.lua.
function M.resolve_for_build(params)
  if type(params.string) == "string" and params.string ~= "" then
    return with_imported(params.string, function(stack)
      local norm = normalize(stack)
      return {
        label = try(function() return stack.label end),
        where = "export string",
        entities = norm.list,
        items_needed = norm.items_needed,
        skipped = norm.skipped,
        size = norm.size,
      }
    end)
  end
  local chosen = choose_holder(params)
  local norm = normalize(chosen.holder)
  return {
    label = chosen.label,
    where = chosen.where,
    book = chosen.book,
    entities = norm.list,
    items_needed = norm.items_needed,
    skipped = norm.skipped,
    size = norm.size,
  }
end

return M
