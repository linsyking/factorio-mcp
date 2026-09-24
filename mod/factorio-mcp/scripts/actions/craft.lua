-- craft: hand-crafting via the character crafting queue. begin_crafting
-- returns how many it actually started; the queue progresses on a detached
-- character and is polled via crafting_queue_size.
local companion = require("scripts.companion")
local stats = require("scripts.stats")

local M = {}

local POLL_TICKS = 30
local MAX_COUNT = 1000

-- What's short for `count` crafts, e.g. "2x iron-plate, 1x iron-gear-wheel".
-- Must run BEFORE begin_crafting consumes the ingredients.
local function missing_ingredients(c, recipe, count)
  local parts = {}
  for _, ing in ipairs(recipe.ingredients or {}) do
    if ing.type == "item" then
      local have = c.get_item_count(ing.name)
      local need = ing.amount * count
      if have < need then
        parts[#parts + 1] = string.format("%dx %s", need - have, ing.name)
      end
    end
  end
  return table.concat(parts, ", ")
end

function M.start(task)
  local c = companion.require_companion()
  if type(task.recipe) ~= "string" then
    error("craft requires recipe = <recipe name>")
  end
  local count = math.floor(tonumber(task.count) or 1)
  if count < 1 then count = 1 end
  local capped = count > MAX_COUNT
  if capped then count = MAX_COUNT end
  task.count = count

  local r = c.force.recipes[task.recipe]
  if not r then
    error("unknown recipe: '" .. task.recipe .. "'")
  end
  if not r.enabled then
    error("recipe " .. task.recipe .. " isn't unlocked yet — research it first")
  end

  local product_names, before = {}, {}
  for _, p in ipairs(r.products or {}) do
    if p.type == "item" then
      product_names[#product_names + 1] = p.name
      before[p.name] = c.get_item_count(p.name)
    end
  end

  local missing = missing_ingredients(c, r, count)
  local started = c.begin_crafting({ count = count, recipe = task.recipe })
  if started == 0 then
    if missing ~= "" then
      error("can't craft " .. task.recipe .. " — missing ingredients: " .. missing)
    end
    local handcraftable = false
    pcall(function() handcraftable = c.prototype.crafting_categories[r.category] == true end)
    if handcraftable then
      error("can't craft " .. task.recipe .. " — not enough ingredients for its intermediates (the whole chain is "
        .. "checked); craftable now: " .. tostring(c.get_craftable_count(task.recipe)))
    end
    error("can't craft " .. task.recipe .. " — this recipe can't be crafted by hand (category " .. tostring(r.category) .. ")")
  end

  local note = capped and string.format(" (capped at %d per job)", MAX_COUNT) or ""
  if started < count then
    note = string.format(" (only started %d of %d — missing ingredients: %s)",
      started, count, missing ~= "" and missing or "not enough materials")
  end
  task._craft = {
    started = started,
    note = note,
    product_names = product_names,
    products_before = before,
    next_poll = game.tick + POLL_TICKS,
  }
end

function M.tick(task)
  local c = companion.get()
  if not c then
    return { status = "failed", detail = "the companion character is gone" }
  end
  local s = task._craft
  if game.tick < s.next_poll then return nil end
  s.next_poll = game.tick + POLL_TICKS
  if c.crafting_queue_size > 0 then return nil end

  local parts = {}
  for _, name in ipairs(s.product_names) do
    local gained = c.get_item_count(name) - s.products_before[name]
    if gained > 0 then
      stats.record_produced(c, name, gained)
      parts[#parts + 1] = string.format("+%d %s", gained, name)
    end
  end
  return {
    status = "done",
    detail = string.format("crafted %dx %s%s%s", s.started, task.recipe,
      #parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or "", s.note),
  }
end

-- Cancel everything in the character's crafting queue (last first, so queue
-- indices stay valid); the engine refunds the ingredients. Returns how many
-- crafts were cancelled. Jobs run one at a time, so while a craft (or a
-- build_plan preparing items) is the active job, the queue is all its own.
function M.cancel_queue(c)
  local n = 0
  for _ = 1, 1000 do
    if not c or c.crafting_queue_size == 0 then break end
    -- refunds that don't fit would be spilled by the engine (onto belts,
    -- if any are near): stop while the inventory is nearly full and let the
    -- remaining crafts finish instead
    local inv = c.get_main_inventory()
    if inv and inv.count_empty_stacks() < 2 then break end
    local q = c.crafting_queue
    local last = q and q[#q]
    if not last then break end
    local ok = pcall(function() c.cancel_crafting({ index = last.index, count = last.count }) end)
    if not ok then break end
    n = n + last.count
  end
  return n
end

-- Called by tasks.lua when an active craft job is cancelled or fails: the
-- engine would otherwise keep crafting (the full batch's ingredients were
-- taken when crafting began), which looked like lost ingredients.
function M.stop(task)
  if task._craft then M.cancel_queue(companion.get()) end
end

return M
