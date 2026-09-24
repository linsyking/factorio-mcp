-- Building actions: place, rotate, set_recipe. Each approaches its target
-- first (build_distance for place, reach_distance otherwise).
local companion = require("scripts.companion")
local placement = require("scripts.placement")
local items = require("scripts.items")
local approach = require("scripts.actions.approach")
local build_plan = require("scripts.actions.build_plan")
local belts = require("scripts.belts")
local provenance = require("scripts.provenance")

local M = {}

local direction_names = {}
for name, value in pairs(defines.direction) do
  direction_names[value] = name
end

local function dir_name(d)
  return direction_names[d] or tostring(d)
end

local function validate_position(pos, action)
  if type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.y) ~= "number" then
    error(action .. " requires target = {x, y}")
  end
end

local function gone()
  return { status = "failed", detail = "the companion character is gone" }
end

-- ------------------------------------------------------------------ place


M.place = {}

function M.place.start(task)
  local c = companion.require_companion()
  if type(task.item) ~= "string" then
    error("place requires item = <item name>")
  end
  if type(task.position) ~= "table" or type(task.position.x) ~= "number" or type(task.position.y) ~= "number" then
    error("place requires position = {x, y}")
  end
  local item_name, item_quality = items.parse(task.item)
  local proto = prototypes.item[item_name]
  if not proto then
    error("no item called '" .. task.item .. "'")
  end
  local result = proto.place_result
  if not result then
    error(task.item .. " is not a placeable item")
  end
  task._quality = item_quality
  if items.count(c, task.item) == 0 then
    error("I don't have any " .. task.item .. " in my inventory — craft or collect one first")
  end
  task.direction = math.floor(tonumber(task.direction) or 0) % 16
  task._entity_name = result.name
  local bad_dir = placement.check_direction(result.name, task.direction)
  if bad_dir then error(bad_dir) end
  task.position = placement.snap(result, task.position, task.direction)
  if task.recipe ~= nil then
    -- checked before walking, like set_recipe
    local r = c.force.recipes[tostring(task.recipe)]
    if not r then error("unknown recipe: '" .. tostring(task.recipe) .. "'") end
    if not r.enabled then error("recipe " .. tostring(task.recipe) .. " isn't unlocked yet — research it first") end
  end
end

function M.place.tick(task)
  local c = companion.get()
  if not c then return gone() end

  local reached = approach.ensure(task, c, task.position, c.build_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end

  if items.count(c, task.item) == 0 then
    return { status = "failed", detail = "I no longer have any " .. task.item .. " in my inventory" }
  end

  local aside = approach.step_aside(task, c,
    placement.footprint(prototypes.entity[task._entity_name], task.position, task.direction))
  if type(aside) == "table" then return aside end
  if aside ~= "ok" then return nil end

  local occ, occ_items = placement.occupant(c, task._entity_name, task.position, task.direction)
  if occ and not task.fast_replace then
    return {
      status = "failed",
      detail = string.format("the %s at (%.1f, %.1f)%s is in the way — deconstruct it first, or pass fast_replace=true "
        .. "to swap it like a player does (its contents move over)", occ.name, occ.position.x, occ.position.y,
        occ_items > 0 and string.format(" holding %d items", occ_items) or ""),
    }
  end

  -- The engine has no same-name fast replace: its manual build check refuses
  -- a tile held by an identical entity (the real game does nothing when you
  -- place a wall over a wall), so a same-item fast_replace always died at
  -- "blocked by stone-wall" at the target's own position, never reaching
  -- create_entity. Same item + fast_replace is a REFRESH: hand the old one
  -- back (like deconstruct) and place the new one fresh — damaged-wall
  -- maintenance is the standing use.
  local refresh, refresh_note = nil, ""
  if occ and task.fast_replace == true then
    local q = (occ.quality and occ.quality.name) or "normal"
    if occ.name == task._entity_name and q == (task._quality or "normal") then refresh = occ end
  end
  local swap = false
  if refresh then
    local inv = c.get_main_inventory()
    local removed = false
    if inv then pcall(function() removed = refresh.mine({ inventory = inv, raise_destroyed = true }) end) end
    if not removed then
      return {
        status = "failed",
        detail = string.format("couldn't take down the old %s at (%.1f, %.1f) to replace it — my inventory is probably full",
          refresh.name, refresh.position.x, refresh.position.y),
      }
    end
    refresh_note = " — replaced the old one (returned to my inventory)"
  else
    local can_place = c.surface.can_place_entity({
      name = task._entity_name,
      position = task.position,
      direction = task.direction,
      force = c.force,
      build_check_type = defines.build_check_type.manual,
    })
    if not can_place then
      return {
        status = "failed",
        detail = string.format("can't place %s at (%.1f, %.1f) — %s",
          task.item, task.position.x, task.position.y, placement.explain(c, task._entity_name, task.position, task.direction)),
      }
    end
    swap = occ ~= nil
  end

  local built = c.surface.create_entity({
    name = task._entity_name,
    position = task.position,
    direction = task.direction,
    force = c.force,
    quality = task._quality,
    type = task.underground_type, -- underground belts: "input" or "output"
    raise_built = true,
    -- a player-style fast replace: the old building goes to this character
    -- and its contents into the new one (what fits)
    fast_replace = swap and task.fast_replace == true or nil,
    character = (swap and task.fast_replace == true) and c or nil,
  })
  if not built then
    return {
      status = "failed",
      detail = string.format("placing %s at (%.1f, %.1f) failed unexpectedly — try a slightly different spot",
        task.item, task.position.x, task.position.y),
    }
  end
  c.remove_item(items.spec(task.item, 1))
  provenance.record(built, string.format("placed%s", task.direction ~= 0
    and (" facing " .. dir_name(task.direction)) or ""), task)
  local recipe_note = ""
  if task.recipe ~= nil and built.valid then
    local why = build_plan.apply_recipe(c, built, tostring(task.recipe), task)
    if why then
      return { status = "failed", detail = string.format("placed %s at (%.1f, %.1f), but %s",
        task.item, built.position.x, built.position.y, why) }
    end
    recipe_note = ", recipe " .. tostring(task.recipe)
  end
  if built.valid and built.type == "underground-belt" then
    -- say whether it paired: an unpaired entrance swallows nothing and passes nothing
    local note, paired = belts.underground_note(built)
    recipe_note = recipe_note .. " — underground " .. note
      .. ((not paired and built.belt_to_ground_type == "input") and " (normal until you place its exit)" or "")
  end
  return {
    status = "done",
    detail = string.format("placed %s at (%.1f, %.1f)%s%s%s",
      task.item, built.position.x, built.position.y,
      task.direction ~= 0 and (" facing " .. dir_name(task.direction)) or "", refresh_note, recipe_note),
  }
end

-- ----------------------------------------------------------------- rotate

M.rotate = {}

function M.rotate.start(task)
  companion.require_companion()
  validate_position(task.target, "rotate")
  if task.direction ~= nil then
    task.direction = math.floor(tonumber(task.direction) or 0) % 16
  end
end

function M.rotate.tick(task)
  local c = companion.get()
  if not c then return gone() end

  local reached = approach.ensure(task, c, task.target, c.reach_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end

  local e, pick_note = approach.find_entity_near(c, task.target)
  task._pick_note = pick_note
  if not e then
    return {
      status = "failed",
      detail = string.format("nothing to rotate at (%.1f, %.1f)", task.target.x, task.target.y),
    }
  end

  if task.direction then
    local ok = pcall(function() e.direction = task.direction end)
    if not ok or e.direction ~= task.direction then
      return { status = "failed", detail = "the " .. e.name .. " can't face that way" }
    end
    provenance.record(e, string.format("rotated to face %s", dir_name(task.direction)), task)
    return {
      status = "done",
      detail = string.format("turned the %s at (%.1f, %.1f) to face %s",
        e.name, e.position.x, e.position.y, dir_name(task.direction)),
    }
  end

  if not e.rotate() then
    return { status = "failed", detail = "the " .. e.name .. " can't be rotated" }
  end
  provenance.record(e, string.format("rotated to face %s", dir_name(e.direction)), task)
  return {
    status = "done",
    detail = string.format("rotated the %s at (%.1f, %.1f) — it now faces %s",
      e.name, e.position.x, e.position.y, dir_name(e.direction)),
  }
end

-- ------------------------------------------------------------- set_recipe

M.set_recipe = {}

function M.set_recipe.start(task)
  local c = companion.require_companion()
  validate_position(task.target, "set_recipe")
  if type(task.recipe) ~= "string" then
    error("set_recipe requires recipe = <recipe name>")
  end
  local r = c.force.recipes[task.recipe]
  if not r then
    error("unknown recipe: '" .. task.recipe .. "'")
  end
  if not r.enabled then
    error("recipe " .. task.recipe .. " isn't unlocked yet — research it first")
  end
end

function M.set_recipe.tick(task)
  local c = companion.get()
  if not c then return gone() end

  local reached = approach.ensure(task, c, task.target, c.reach_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end

  local e, pick_note = approach.find_entity_near(c, task.target)
  task._pick_note = pick_note
  if not e then
    return {
      status = "failed",
      detail = string.format("nothing at (%.1f, %.1f) to set a recipe on", task.target.x, task.target.y),
    }
  end
  if e.type ~= "assembling-machine" then
    if e.type == "furnace" then
      return {
        status = "failed",
        detail = "the " .. e.name .. " is a furnace — it picks its recipe automatically from what you insert",
      }
    end
    return { status = "failed", detail = "the " .. e.name .. " can't have a recipe set — only crafting machines can" }
  end

  local ok, removed = pcall(e.set_recipe, task.recipe)
  if not ok then
    return {
      status = "failed",
      detail = string.format("couldn't set %s on the %s — that machine probably can't craft it",
        task.recipe, e.name),
    }
  end

  -- Ingredients of the previous recipe come back to us; overflow spills.
  local taken, dropped = 0, 0
  if type(removed) == "table" then
    for _, stack in ipairs(removed) do
      if stack.name and (stack.count or 0) > 0 then
        local d = items.give(c, { name = stack.name, count = stack.count, quality = stack.quality })
        taken = taken + stack.count - d
        dropped = dropped + d
      end
    end
  end
  provenance.record(e, string.format("set recipe to %s", task.recipe), task)
  return {
    status = "done",
    detail = string.format("set %s's recipe to %s%s%s", e.name, task.recipe,
      taken > 0 and string.format(" (took %d leftover items into my inventory)", taken) or "",
      dropped > 0 and string.format("; %d didn't fit and are on the ground at my feet", dropped) or ""),
  }
end

return M
