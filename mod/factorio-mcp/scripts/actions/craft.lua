-- craft: hand-crafting via the character crafting queue. begin_crafting
-- returns how many it actually started; the queue progresses on a detached
-- character and is polled via crafting_queue_size. count is recipe
-- EXECUTIONS: one craft of a multi-output recipe (transport-belt,
-- copper-cable) yields its recipe result per craft, and the done report
-- states items MADE separately from items in POCKET, because the character
-- can use items while the queue runs.
local companion = require("scripts.companion")
local events = require("scripts.events")
local items = require("scripts.items")
local stats = require("scripts.stats")

local M = {}

local POLL_TICKS = 30
local MAX_COUNT = 1000
-- A queue that makes no progress while the inventory is nearly full is
-- stalled: Factorio holds completed results in the queue until slots free
-- up, while the ingredients of started crafts are already spent. 40 polls
-- of 30 ticks = 20s — past any single hand-craft — with the queue frozen.
local STALL_POLLS = 40

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

  local product_names, product_amounts, before, inv_before = {}, {}, {}, nil
  for _, p in ipairs(r.products or {}) do
    if p.type == "item" then
      product_names[#product_names + 1] = p.name
      product_amounts[p.name] = p.amount or 1
      before[p.name] = c.get_item_count(p.name)
    end
  end
  pcall(function() inv_before = items.inventory_map(c.get_main_inventory()) end)

  -- How many the engine could craft right now through the whole ingredient
  -- chain (intermediates included) — the honest ceiling behind a partial
  -- start, which the direct-ingredient list alone doesn't explain.
  local chainable
  pcall(function() chainable = c.get_craftable_count(task.recipe) end)

  local missing = missing_ingredients(c, r, count)
  local started = c.begin_crafting({ count = count, recipe = task.recipe })
  if started == 0 then
    if missing ~= "" then
      error("can't craft " .. task.recipe .. " — missing ingredients (crafts draw from what you carry, not from "
        .. "chests): " .. missing)
    end
    local handcraftable = false
    pcall(function() handcraftable = c.prototype.crafting_categories[r.category] == true end)
    if handcraftable then
      error("can't craft " .. task.recipe .. " — not enough ingredients for its intermediates (the whole chain is "
        .. "checked); craftable now: " .. tostring(chainable))
    end
    error("can't craft " .. task.recipe .. " — this recipe can't be crafted by hand (category " .. tostring(r.category) .. ")")
  end

  local note = capped and string.format(" (capped at %d per job)", MAX_COUNT) or ""
  if started < count then
    note = string.format(" (only started %d of %d — the ingredient chain, intermediates included, had materials "
      .. "for %d; directly short: %s. Crafts draw from what you carry, not from chests)",
      started, count, chainable or started, missing ~= "" and missing or "not enough materials")
  end

  -- What the engine auto-queued on top of the requested crafts (crafting a
  -- green circuit queues inserters, then circuits, then cable...).
  local depth_note = ""
  local depth = nil
  pcall(function() depth = c.crafting_queue_size end)
  if depth and depth > started then
    local names = {}
    pcall(function()
      for _, q in ipairs(c.crafting_queue) do
        local rn = nil
        if type(q.recipe) == "string" then
          rn = q.recipe
        else
          pcall(function() rn = q.recipe.name end)
        end
        if rn and rn ~= task.recipe then names[rn] = true end
      end
    end)
    local list = {}
    for n in pairs(names) do list[#list + 1] = n end
    table.sort(list)
    if #list > 4 then
      for i = #list, 5, -1 do list[i] = nil end
      list[#list + 1] = "..."
    end
    depth_note = string.format("; the queue holds %d crafts now (auto-queued intermediates: %s)",
      depth, #list > 0 and table.concat(list, ", ") or "various")
  end

  local room_note = ""
  pcall(function()
    local inv = c.get_main_inventory()
    if inv and inv.count_empty_stacks() < 2 then
      room_note = "; WARNING: inventory nearly full — completed results are held back while nothing fits"
    end
  end)

  task._craft = {
    started = started,
    note = note .. depth_note .. room_note,
    product_names = product_names,
    product_amounts = product_amounts,
    products_before = before,
    inventory_before = inv_before or {},
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

  local size = nil
  pcall(function() size = c.crafting_queue_size end)
  if size == nil then size = 0 end
  if size > 0 then
    -- Stall watch: no queue progress for STALL_POLLS while the inventory is
    -- nearly full means completed results are being held for lack of space.
    if size == s.last_size then
      s.frozen = (s.frozen or 0) + 1
    else
      s.frozen = 0
    end
    s.last_size = size
    if s.frozen >= STALL_POLLS then
      local empty = 99
      pcall(function()
        local inv = c.get_main_inventory()
        if inv then empty = inv.count_empty_stacks() end
      end)
      if empty < 2 then
        return {
          status = "failed",
          detail = string.format("crafting stalled: %d crafts queued with no progress for %ds and the inventory "
            .. "is full (%d free slot%s) — completed results are held back until slots free up. Deposit items "
            .. "into a chest to make room; whatever was already crafted is in your inventory, and the rest of the "
            .. "queue either keeps crafting as slots free or was refunded — check before re-crafting",
            size, math.floor(STALL_POLLS * POLL_TICKS / 60), empty, empty == 1 and "" or "s"),
        }
      end
    end
    return nil
  end

  -- Queue drained: every started craft completed its recipe result. Pocket
  -- counts are a NET delta — the character can use items mid-craft — so both
  -- numbers are reported when they differ.
  local made_parts, pocket_parts = {}, {}
  for _, name in ipairs(s.product_names) do
    local per = s.product_amounts[name] or 1
    local made = s.started * per
    local gained = c.get_item_count(name) - s.products_before[name]
    stats.record_produced(c, name, made)
    local each = per > 1 and string.format(" (%d per craft)", per) or ""
    made_parts[#made_parts + 1] = string.format("%d %s%s", made, name, each)
    if gained ~= made then
      pocket_parts[#pocket_parts + 1] = string.format("%s %+d in pocket", name, gained)
    end
  end
  return {
    status = "done",
    detail = string.format("crafted %dx %s -> %s%s%s",
      s.started, task.recipe, table.concat(made_parts, ", "),
      #pocket_parts > 0 and (" (" .. table.concat(pocket_parts, ", ") .. " — net of any you used while it ran)") or "",
      s.note),
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
-- taken when crafting began), which looked like lost ingredients. The
-- queue's already-crafted items — products AND auto-queued intermediates —
-- stay in the inventory; an event reports them so they never read as a loss.
function M.stop(task)
  if not task._craft then return end
  local c = companion.get()
  if not c then return end
  local n = M.cancel_queue(c)
  local stays = {}
  pcall(function()
    local after = items.inventory_map(c.get_main_inventory())
    for k, v in pairs(after) do
      local d = v - (task._craft.inventory_before[k] or 0)
      if d > 0 then stays[#stays + 1] = string.format("+%d %s", d, k) end
    end
  end)
  table.sort(stays)
  local msg = string.format("craft cancelled: %d queued craft%s refunded", n, n == 1 and "" or "s")
  if #stays > 0 then
    msg = msg .. "; already crafted, kept: " .. table.concat(stays, ", ")
  end
  pcall(function() events.push("craft_cancelled", msg) end)
end

return M
