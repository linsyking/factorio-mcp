-- Character registry. One MCP instance binds ONE named character
-- (1 agent <-> 1 MCP instance <-> 1 character); many instances run at once.
--
-- A transient per-call context selects which character the current RPC/task
-- acts on: rpc.lua sets it from params.companion after checking the binding,
-- tasks.lua sets it per lane before each tick.
--
-- Fairness: characters spawn at the force spawn point like a new player, get
-- exactly the freeplay scenario's start/respawn kit (if the scenario has one),
-- and never get speed modifiers.
local vision = require("scripts.vision")

local M = {}


M.DEFAULT = "agent"
local NAME_MAX = 32
local LEASE_TICKS = 60 * 60 -- a session silent for 60 s may be taken over

local PALETTE = {
  { r = 0.30, g = 0.79, b = 0.69, a = 1 }, -- teal
  { r = 0.90, g = 0.62, b = 0.20, a = 1 }, -- amber
  { r = 0.66, g = 0.55, b = 0.96, a = 1 }, -- violet
  { r = 0.86, g = 0.42, b = 0.55, a = 1 }, -- rose
  { r = 0.45, g = 0.70, b = 0.95, a = 1 }, -- sky
  { r = 0.70, g = 0.85, b = 0.35, a = 1 }, -- lime
}

local LABEL_OFFSET = { 0, -2.9 }
local MAP_TAG_MOVE_SQ = 9

-- Transient (NOT storage-safe, deliberately): valid only within one call/tick.
local current_name = nil

function M.set_context(name)
  current_name = (type(name) == "string" and name ~= "") and name or nil
end

function M.context()
  return current_name or M.DEFAULT
end

local function records()
  storage.companions = storage.companions or {}
  return storage.companions
end

local function bindings()
  storage.bindings = storage.bindings or {}
  return storage.bindings
end

local function max_characters()
  local s = settings and settings.global and settings.global["factorio-mcp-max-characters"]
  return (s and tonumber(s.value)) or 32
end

local function valid_name(name)
  if type(name) ~= "string" or name == "" then error("a character name is required") end
  if #name > NAME_MAX then error("character names must be " .. NAME_MAX .. " characters or fewer") end
  if not name:match("^[%w%-_ ]+$") then
    error("character names may only contain letters, digits, spaces, '-' and '_'")
  end
  return name
end

-- No speed bonuses, ever: reset anything an older mod version may have set.
local function normalize_body(ent)
  if not (ent and ent.valid) then return end
  pcall(function()
    ent.character_running_speed_modifier = 0
    ent.character_mining_speed_modifier = 0
    ent.character_crafting_speed_modifier = 0
  end)
end

function M.names()
  local out = {}
  for name in pairs(records()) do out[#out + 1] = name end
  table.sort(out)
  return out
end

function M.get(name)
  local rec = records()[name or M.context()]
  local ent = rec and rec.entity
  if ent and ent.valid then return ent end
  return nil
end

function M.record(name)
  return records()[name or M.context()]
end

function M.require_companion(name)
  local ent = M.get(name)
  if not ent then
    error("your character '" .. (name or M.context()) .. "' has no body right now (died?) — call respawn")
  end
  return ent
end

-- All live character entities we control (for vision updates, event routing).
function M.entities()
  local out = {}
  for _, rec in pairs(records()) do
    if rec.entity and rec.entity.valid then out[#out + 1] = rec.entity end
  end
  return out
end

function M.name_of(entity)
  for name, rec in pairs(records()) do
    if rec.entity and rec.entity.valid and rec.entity == entity then return name end
    if rec.unit_number and entity.unit_number == rec.unit_number then return name end
  end
  return nil
end

local function count_companions()
  local n = 0
  for _ in pairs(records()) do n = n + 1 end
  return n
end

local function color_for(name)
  local idx = 1
  for i, n in ipairs(M.names()) do
    if n == name then idx = i break end
  end
  return PALETTE[(idx - 1) % #PALETTE + 1]
end

-- Floating name tag so humans can tell agent characters apart.
local function attach_label(rec, name, ent)
  pcall(function()
    if rec.label and rec.label.valid then rec.label.destroy() end
  end)
  rec.label = nil
  local ok, obj = pcall(function()
    return rendering.draw_text({
      text = name,
      surface = ent.surface,
      target = { entity = ent, offset = LABEL_OFFSET },
      color = color_for(name),
      scale = 1.4,
      alignment = "center",
      scale_with_zoom = true,
    })
  end)
  if ok and obj then rec.label = obj end
end

-- Map markers for every character; chart tags can't move, so re-pin after
-- drifting. Runs on_nth_tick (wired in control.lua) — must never raise.
function M.update_map_tag()
  for name, rec in pairs(records()) do
    local ent = rec.entity
    local alive = ent and ent.valid
    local tag = rec.map_tag
    local tag_valid = false
    pcall(function() tag_valid = tag and tag.valid end)

    if not alive then
      if tag_valid then pcall(function() tag.destroy() end) end
      rec.map_tag = nil
    else
      local label_valid = false
      pcall(function() label_valid = rec.label and rec.label.valid end)
      if not label_valid then attach_label(rec, name, ent) end

      local keep = false
      if tag_valid then
        local p = tag.position
        local dx, dy = p.x - ent.position.x, p.y - ent.position.y
        keep = dx * dx + dy * dy < MAP_TAG_MOVE_SQ
        if not keep then pcall(function() tag.destroy() end) end
      end
      if not keep then
        rec.map_tag = nil
        pcall(function()
          rec.map_tag = ent.force.add_chart_tag(ent.surface, {
            position = ent.position,
            text = name,
            icon = { type = "virtual", name = "signal-A" },
          })
        end)
      end
    end
  end
end

-- The freeplay scenario's item kits, so an agent starts exactly like a new
-- player (created_items) and respawns like one (respawn_items).
local function scenario_kit(kind)
  local ok, items = pcall(function()
    local iface = remote.interfaces["freeplay"]
    if iface and iface["get_" .. kind] then return remote.call("freeplay", "get_" .. kind) end
    return nil
  end)
  if ok and type(items) == "table" then return items end
  return {}
end

local function give_kit(ent, kind)
  local given = {}
  for name, count in pairs(scenario_kit(kind)) do
    if prototypes.item[name] and count > 0 then
      local n = ent.insert({ name = name, count = count })
      if n > 0 then given[name] = n end
    end
  end
  return given
end

local function body_summary(name, ent, already_existed, kit)
  return {
    name = name,
    position = { x = ent.position.x, y = ent.position.y },
    surface = ent.surface.name,
    unit_number = ent.unit_number,
    already_existed = already_existed,
    kit = kit,
  }
end

-- Creates (or returns) the named character at the force spawn point.
local function spawn_body(name)
  local existing = M.get(name)
  if existing then
    normalize_body(existing)
    pcall(function()
      vision.grant_start_area(existing.surface, existing.force, existing.force.get_spawn_position(existing.surface))
    end)
    return body_summary(name, existing, true, nil)
  end
  local rec = records()[name]
  if not rec and count_companions() >= max_characters() then
    error("the server allows at most " .. max_characters() .. " agent characters (mod setting "
      .. "factorio-mcp-max-characters); existing: " .. table.concat(M.names(), ", "))
  end

  local force = game.forces.player
  local surface = game.surfaces.nauvis or game.surfaces[1]
  local anchor = force.get_spawn_position(surface)
  local pos = surface.find_non_colliding_position("character", anchor, 32, 0.5)
  if not pos then error("no free spot near the spawn point to create a character") end

  local ent = surface.create_entity({ name = "character", position = pos, force = force, raise_built = true })
  if not ent then error("failed to create the character") end

  local respawn = rec ~= nil
  rec = rec or {}
  records()[name] = rec
  rec.entity = ent
  rec.unit_number = ent.unit_number
  ent.color = color_for(name)
  normalize_body(ent)
  local kit = give_kit(ent, respawn and "respawn_items" or "created_items")
  pcall(function() vision.grant_start_area(surface, force, anchor) end)
  attach_label(rec, name, ent)
  M.update_map_tag()
  return body_summary(name, ent, false, kit)
end

-- rpc "respawn": re-create the bound character's body after death.
function M.spawn(params)
  return spawn_body(valid_name(params.name or M.context()))
end

-- ---------------------------------------------------------------- binding

-- bind {name, session, takeover?}: claim a character for one MCP session and
-- make sure it has a body. A character held by another session that called
-- within the lease window is refused unless takeover=true.
function M.bind(params)
  local name = valid_name(params.name)
  local session = params.session
  if type(session) ~= "string" or #session < 8 or #session > 80 then
    error("bind requires a session token (8-80 characters)")
  end
  local b = bindings()[name]
  local took_over = false
  if b and b.session ~= session then
    local idle = game.tick - (b.last_seen or 0)
    if idle < LEASE_TICKS and not params.takeover then
      error(string.format(
        "character '%s' is bound to another live MCP session (last active %.0fs ago) — "
          .. "use a different character name, or take over explicitly", name, idle / 60))
    end
    took_over = true
  end
  bindings()[name] = { session = session, last_seen = game.tick, since = game.tick }
  -- A brand-new character starts reading chat/events from "now".
  storage.cursors = storage.cursors or {}
  if not storage.cursors[name] then
    storage.cursors[name] = {
      chat = (storage.chat and storage.chat.next_id or 1) - 1,
      events = (storage.events and storage.events.next_id or 1) - 1,
    }
  end
  local body = spawn_body(name)
  pcall(function() vision.mark(M.get(name)) end)
  body.bound = true
  body.took_over = took_over
  return body
end

-- Every scoped RPC refreshes its session's lease (rpc.lua).
function M.touch(name, session)
  local b = bindings()[name or ""]
  if not b or b.session ~= session then
    error("this MCP session does not hold character '" .. tostring(name)
      .. "' (never bound, or another session took it over) — reconnect to bind again")
  end
  b.last_seen = game.tick
end

function M.unbind(params)
  local name = params.companion
  local b = bindings()[name or ""]
  if b and b.session == params.session then bindings()[name] = nil end
  return {}
end

-- retire: remove the bound character from the game entirely (body with its
-- inventory, label, map tag, binding). Used to clean up test characters.
function M.retire()
  local name = M.context()
  local rec = records()[name]
  if rec then
    pcall(function() if rec.label and rec.label.valid then rec.label.destroy() end end)
    pcall(function() if rec.map_tag and rec.map_tag.valid then rec.map_tag.destroy() end end)
    if rec.entity and rec.entity.valid then rec.entity.destroy() end
    records()[name] = nil
  end
  bindings()[name] = nil
  if storage.cursors then storage.cursors[name] = nil end
  if storage.scan_letters then storage.scan_letters[name] = nil end
  return { retired = name }
end

function M.binding_summary()
  local out = {}
  for name, b in pairs(bindings()) do
    out[#out + 1] = { name = name, idle_s = math.floor((game.tick - (b.last_seen or 0)) / 60) }
  end
  table.sort(out, function(a, c) return a.name < c.name end)
  return out
end

function M.normalize_all()
  for _, rec in pairs(records()) do normalize_body(rec.entity) end
end

return M
