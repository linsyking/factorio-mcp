-- Event log: things that happen while nobody asked (job finished/failed, a
-- character attacked or killed, research finished, duty supply warnings).
-- A ring buffer read with cursors (since_id) — reads never consume, so any
-- number of MCP instances can follow it. Each instance only sees events for
-- its own character plus force-wide ones (no companion field).
local companion = require("scripts.companion")

local M = {}

local MAX_EVENTS = 100
local ATTACK_THROTTLE_TICKS = 300 -- one "attacked" event per 5s

-- Lazy init guard: handlers can fire before a version-bump migration runs.
local function buffer()
  storage.events = storage.events or { list = {}, next_id = 1 }
  return storage.events
end

function M.push(kind, text, extra)
  local ev = buffer()
  local e = { id = ev.next_id, tick = game.tick, kind = kind, text = text }
  if extra then
    for k, v in pairs(extra) do e[k] = v end
  end
  ev.next_id = ev.next_id + 1
  ev.list[#ev.list + 1] = e
  if #ev.list > MAX_EVENTS then
    table.remove(ev.list, 1)
  end
end

function M.get(params)
  local me = companion.context()
  storage.cursors = storage.cursors or {}
  local cur = storage.cursors[me]
  local since = tonumber(params.since_id) or (cur and cur.events) or 0
  local ev = buffer()
  local out = {}
  for _, e in ipairs(ev.list) do
    if e.id > since and (e.companion == nil or e.companion == me) then
      out[#out + 1] = e
    end
  end
  local last = ev.next_id - 1
  if cur then cur.events = math.max(cur.events or 0, last) end
  return { events = out, last_id = last }
end

local function companion_name_of(entity)
  return companion.name_of(entity)
end

-- Wired with an event filter on type "character" in control.lua.
function M.on_entity_damaged(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  local name = companion_name_of(entity)
  if not name then return end
  local now = game.tick
  local ev = buffer()
  ev.last_attack_tick_by = ev.last_attack_tick_by or {}
  local last = ev.last_attack_tick_by[name]
  if last and now - last < ATTACK_THROTTLE_TICKS then
    return
  end
  ev.last_attack_tick_by[name] = now
  M.push("attacked", string.format(
    "%s is being attacked: health %d/%s at (%.1f, %.1f).",
    name,
    math.floor(entity.health or 0),
    tostring(math.floor(entity.max_health or 250)),
    entity.position.x, entity.position.y), { companion = name })
end

function M.on_entity_died(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  local name = companion_name_of(entity)
  if not name then return end
  M.push("died", string.format(
    "%s died at (%.1f, %.1f); the inventory stays in the corpse there. respawn creates a new body at the spawn point.",
    name, entity.position.x, entity.position.y), { companion = name })
end

function M.on_research_finished(event)
  local tech = event.research
  if not tech then return end
  local queue_len = 0
  pcall(function() queue_len = #tech.force.research_queue end)
  M.push("research_finished", string.format(
    "Research completed: %s. %s", tech.name,
    queue_len > 0 and "The research queue continues." or "The research queue is now empty."))
end

return M
