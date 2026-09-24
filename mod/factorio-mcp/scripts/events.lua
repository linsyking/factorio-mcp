-- Event log: things that happen while nobody asked (job finished/failed, a
-- character attacked or killed, our buildings damaged or destroyed, research
-- finished, duty supply warnings). A ring buffer read with cursors
-- (since_id) — reads never consume, so any number of MCP instances can
-- follow it. Each instance only sees events for its own character plus
-- force-wide ones (no companion field).
local companion = require("scripts.companion")

local M = {}

local MAX_EVENTS = 100
local ATTACK_THROTTLE_TICKS = 300 -- one "attacked" event per 5s
local COMBAT_WINDOW_TICKS = 300 -- 5s aggregation window for force-entity damage
local COMBAT_LISTED = 5 -- entities named per "under attack" event
local COMBAT_KINDS = { attacked = true, died = true, under_attack = true, destroyed = true }

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

-- Force-entity combat events, aggregated so an attack wave can't flood the
-- ring: damage lands in a 5s window buffer, flushed as ONE force-wide
-- "under_attack" event (worst entity first); deaths push immediately.
-- Wired with a force filter ("player") in control.lua; characters are
-- handled first inside each handler.
local function on_our_force(entity)
  local ok, f = pcall(function() return entity.force end)
  return ok and f ~= nil and f == game.forces.player
end

function M.flush_combat()
  local ev = buffer()
  local cb = ev.combat
  if not cb or not cb.window_tick then return end
  if game.tick - cb.window_tick < COMBAT_WINDOW_TICKS then return end
  local list = {}
  for _, en in pairs(cb.entries) do list[#list + 1] = en end
  ev.combat = { entries = {} }
  if #list == 0 then return end
  table.sort(list, function(a, b) return a.pct < b.pct end)
  local parts = {}
  for i = 1, math.min(#list, COMBAT_LISTED) do
    local en = list[i]
    parts[#parts + 1] = string.format("%s at (%.1f, %.1f) %d/%d", en.name, en.x, en.y, en.hp, en.max_hp)
  end
  if #list > COMBAT_LISTED then
    parts[#parts + 1] = string.format("+%d more", #list - COMBAT_LISTED)
  end
  M.push("under_attack", string.format(
    "UNDER ATTACK: %d of our entities damaged in the last %ds, worst first: %s",
    #list, COMBAT_WINDOW_TICKS / 60, table.concat(parts, ", ")))
end

local function record_combat_damage(entity)
  local ev = buffer()
  ev.combat = ev.combat or { entries = {} }
  if not ev.combat.window_tick then ev.combat.window_tick = game.tick end
  local hp = math.floor((entity.health or 0) + 0.5)
  local max_hp = math.floor((entity.max_health or 1) + 0.5)
  ev.combat.entries[entity.unit_number or (#ev.combat.entries + 1)] = {
    name = entity.name,
    x = entity.position.x,
    y = entity.position.y,
    hp = hp,
    max_hp = max_hp,
    pct = math.floor((entity.health or 0) / math.max(entity.max_health or 1, 1) * 100 + 0.5),
  }
end

function M.on_entity_damaged(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  local name = companion_name_of(entity)
  if name then
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
    return
  end
  if not on_our_force(entity) then return end
  record_combat_damage(entity)
end

function M.on_entity_died(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  local name = companion_name_of(entity)
  if name then
    M.push("died", string.format(
      "%s died at (%.1f, %.1f); the inventory stays in the corpse there. respawn creates a new body at the spawn point.",
      name, entity.position.x, entity.position.y), { companion = name })
    return
  end
  if not on_our_force(entity) then return end
  local cause = ""
  if event.cause and event.cause.valid then
    pcall(function() cause = " by " .. event.cause.name end)
  end
  M.push("destroyed", string.format("our %s at (%.1f, %.1f) was destroyed%s",
    entity.name, entity.position.x, entity.position.y, cause))
end

-- Combat-relevant events from the last `ticks` game ticks, oldest first
-- (for battle_report; reading never consumes — get_events stays the feed).
function M.recent(ticks)
  local cutoff = game.tick - (tonumber(ticks) or 0)
  local out = {}
  for _, e in ipairs(buffer().list) do
    if e.tick >= cutoff and COMBAT_KINDS[e.kind] then
      out[#out + 1] = { tick = e.tick, kind = e.kind, text = e.text }
    end
  end
  return out
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
