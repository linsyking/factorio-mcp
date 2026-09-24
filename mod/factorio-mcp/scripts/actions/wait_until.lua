-- wait_until: hold the job queue until a condition is true, so queued chains
-- don't race the game (extract before smelting finished, craft before a
-- research completed). Exactly one condition:
--   {seconds = N}
--   {item = name, count = N, at = {x, y}?}   N or more of item in the entity at
--                                            `at` (known ground), or in your
--                                            own inventory when `at` is absent
--   {research = technology}                  the technology is researched
-- timeout_s (default 300, max 3600): the job fails when it runs out, and the
-- jobs queued after it are cancelled like after any failure.
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")
local vision = require("scripts.vision")
local items = require("scripts.items")

local M = {}

local CHECK_TICKS = 30

function M.start(task)
  local c = companion.require_companion()
  local n = 0
  if task.seconds ~= nil then n = n + 1 end
  if task.item ~= nil then n = n + 1 end
  if task.research ~= nil then n = n + 1 end
  if n ~= 1 then
    error("wait_until needs exactly one condition: seconds, item (+ count, at?) or research")
  end
  if task.seconds ~= nil then
    local s = tonumber(task.seconds)
    if not s or s < 0 or s > 3600 then error("wait_until seconds must be 0..3600") end
    task._until = game.tick + math.floor(s * 60)
  end
  if task.item ~= nil then
    local name = items.parse(tostring(task.item))
    if not prototypes.item[name] then error("no item called '" .. tostring(task.item) .. "'") end
    task.count = math.max(1, math.floor(tonumber(task.count) or 1))
    if task.at ~= nil then
      if type(task.at) ~= "table" or type(task.at.x) ~= "number" or type(task.at.y) ~= "number" then
        error("wait_until at must be {x, y}")
      end
      vision.require_known(c.surface, c.force, task.at, "what is there")
    end
  end
  if task.research ~= nil then
    local tech = c.force.technologies[tostring(task.research)]
    if not tech then error("no technology called '" .. tostring(task.research) .. "'") end
  end
  local timeout = tonumber(task.timeout_s) or 300
  task._deadline = game.tick + math.floor(math.max(1, math.min(timeout, 3600)) * 60)
  task._next = game.tick
end

local function describe(task)
  if task.seconds ~= nil then return string.format("%gs", tonumber(task.seconds)) end
  if task.research ~= nil then return "research " .. tostring(task.research) end
  local where = task.at and string.format(" in the entity at (%.1f, %.1f)", task.at.x, task.at.y) or " in my inventory"
  return string.format("%d %s%s", task.count, tostring(task.item), where)
end

function M.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  if game.tick < task._next then return nil end
  task._next = game.tick + CHECK_TICKS

  if task.seconds ~= nil then
    if game.tick >= task._until then return { status = "done", detail = "waited " .. describe(task) } end
  elseif task.research ~= nil then
    local tech = c.force.technologies[tostring(task.research)]
    if tech and tech.researched then return { status = "done", detail = describe(task) .. " is done" } end
  else
    local have = 0
    if task.at then
      local e = approach.find_entity_near(c, task.at)
      if e then
        -- every inventory: a furnace's output, an assembler's result, a chest…
        local name = items.parse(tostring(task.item))
        pcall(function()
          for i = 1, e.get_max_inventory_index() do
            local inv = e.get_inventory(i)
            if inv then have = have + inv.get_item_count(name) end
          end
        end)
        task._watched = e.name
      end
    else
      have = items.count(c, tostring(task.item))
    end
    task._have = have
    if have >= task.count then
      return { status = "done", detail = string.format("%s reached (%d)", describe(task), have) }
    end
  end

  if game.tick >= task._deadline then
    local extra = task._have and string.format(" (had %d%s)", task._have,
      task._watched and (" in the " .. task._watched) or "") or ""
    return { status = "failed", detail = "timed out waiting for " .. describe(task) .. extra }
  end
  return nil
end

return M
