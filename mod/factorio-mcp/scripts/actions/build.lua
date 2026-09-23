-- Building actions: place, rotate, set_recipe. Each approaches its target
-- first (build_distance for place, reach_distance otherwise).
local companion = require("scripts.companion")
local placement = require("scripts.placement")
local items = require("scripts.items")
local approach = require("scripts.actions.approach")
local build_plan = require("scripts.actions.build_plan")

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

  local built = c.surface.create_entity({
    name = task._entity_name,
    position = task.position,
    direction = task.direction,
    force = c.force,
    quality = task._quality,
    type = task.underground_type, -- underground belts: "input" or "output"
    raise_built = true,
  })
  if not built then
    return {
      status = "failed",
      detail = string.format("placing %s at (%.1f, %.1f) failed unexpectedly — try a slightly different spot",
        task.item, task.position.x, task.position.y),
    }
  end
  c.remove_item(items.spec(task.item, 1))
  local recipe_note = ""
  if task.recipe ~= nil and built.valid then
    local why = build_plan.apply_recipe(c, built, tostring(task.recipe))
    if why then
      return { status = "failed", detail = string.format("placed %s at (%.1f, %.1f), but %s",
        task.item, built.position.x, built.position.y, why) }
    end
    recipe_note = ", recipe " .. tostring(task.recipe)
  end
  return {
    status = "done",
    detail = string.format("placed %s at (%.1f, %.1f)%s%s",
      task.item, built.position.x, built.position.y,
      task.direction ~= 0 and (" facing " .. dir_name(task.direction)) or "", recipe_note),
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
    return { status = "done", detail = string.format("turned %s to face %s", e.name, dir_name(task.direction)) }
  end

  if not e.rotate() then
    return { status = "failed", detail = "the " .. e.name .. " can't be rotated" }
  end
  return { status = "done", detail = string.format("rotated %s — it now faces %s", e.name, dir_name(e.direction)) }
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
  local taken = 0
  if type(removed) == "table" then
    for _, stack in ipairs(removed) do
      if stack.name and (stack.count or 0) > 0 then
        local inserted = c.insert({ name = stack.name, count = stack.count })
        taken = taken + inserted
        if inserted < stack.count then
          pcall(c.surface.spill_item_stack, {
            position = c.position,
            stack = { name = stack.name, count = stack.count - inserted },
            force = c.force,
          })
        end
      end
    end
  end
  return {
    status = "done",
    detail = string.format("set %s's recipe to %s%s", e.name, task.recipe,
      taken > 0 and string.format(" (took %d leftover items into my inventory)", taken) or ""),
  }
end

return M
