-- Fog of war for player-less characters.
--
-- The engine never charts the map for a character that has no player, and
-- force.chart() does nothing while the force has no players (measured live on
-- 2.0.77, see research/factorio-agent/08-no-cheat-play.md). Without a filter,
-- find_entities_filtered sees every generated chunk, which would let an agent
-- find ore it has never been near. So the mod keeps its own per-force set of
-- explored chunks, and every perception query goes through this module:
--
--   KNOWN   chunk explored by one of our characters, or charted by the force
--           (humans and radars chart for the whole force). Terrain, resources
--           and the force's own buildings are only reported in known chunks.
--   VISIBLE within view radius of one of the force's characters (ours or a
--           connected player's), or in a radar-visible chunk. Live details of
--           other forces (enemies) are only reported when visible.
--
-- Walk goals must be known or within the exploration radius of the character.
local M = {}

local UPDATE_TICKS = 30

local function setting(name, default)
  local s = settings and settings.global and settings.global[name]
  return (s and tonumber(s.value)) or default
end

function M.chart_radius() return setting("factorio-mcp-chart-radius", 2) end     -- chunks
function M.view_radius() return setting("factorio-mcp-view-radius", 32) end      -- tiles
function M.explore_radius() return setting("factorio-mcp-explore-radius", 64) end -- tiles

local function root()
  storage.vision = storage.vision or { explored = {} }
  return storage.vision
end

local function explored_set(force, surface)
  local by_force = root().explored
  local f = by_force[force.index]
  if not f then f = {}; by_force[force.index] = f end
  local s = f[surface.index]
  if not s then s = {}; f[surface.index] = s end
  return s
end

local function chunk_of(pos)
  return math.floor(pos.x / 32), math.floor(pos.y / 32)
end

local function key(cx, cy) return cx .. "," .. cy end

-- Mark the chunks around a character as explored and ask the map generator
-- for the ring beyond, so paths toward the frontier don't hit ungenerated land.
function M.mark(entity)
  if not (entity and entity.valid) then return end
  local set = explored_set(entity.force, entity.surface)
  local cx, cy = chunk_of(entity.position)
  local r = M.chart_radius()
  for dx = -r, r do
    for dy = -r, r do
      set[key(cx + dx, cy + dy)] = true
    end
  end
  pcall(function() entity.surface.request_to_generate_chunks(entity.position, r + 1) end)
end

-- Called from control.lua every UPDATE_TICKS for all our characters.
function M.update(entities)
  for _, e in ipairs(entities) do M.mark(e) end
end

M.UPDATE_TICKS = UPDATE_TICKS

function M.is_known(surface, force, pos)
  local cx, cy = chunk_of(pos)
  if explored_set(force, surface)[key(cx, cy)] then return true end
  local ok, charted = pcall(function() return force.is_chunk_charted(surface, { cx, cy }) end)
  return ok and charted or false
end

-- Viewers: our characters on the force plus connected players' characters.
local function viewers(surface, force)
  local out = {}
  for _, rec in pairs(storage.companions or {}) do
    local e = rec.entity
    if e and e.valid and e.surface == surface and e.force == force then
      out[#out + 1] = e.position
    end
  end
  for _, p in pairs(force.connected_players) do
    if p.surface == surface then out[#out + 1] = p.position end
  end
  return out
end

function M.is_visible(surface, force, pos, cache)
  local r = M.view_radius()
  local r2 = r * r
  local vs = cache and cache.viewers or viewers(surface, force)
  if cache then cache.viewers = vs end
  for _, v in ipairs(vs) do
    local dx, dy = v.x - pos.x, v.y - pos.y
    if dx * dx + dy * dy <= r2 then return true end
  end
  local cx, cy = chunk_of(pos)
  local ok, vis = pcall(function() return force.is_chunk_visible(surface, { cx, cy }) end)
  return ok and vis or false
end

-- Filters keep the input order. Chunk lookups are memoized per call.
function M.filter_known(entities, surface, force)
  local memo, out = {}, {}
  local set = explored_set(force, surface)
  for _, e in ipairs(entities) do
    if e.valid then
      local cx, cy = chunk_of(e.position)
      local k = key(cx, cy)
      local known = memo[k]
      if known == nil then
        known = set[k] == true
        if not known then
          local ok, charted = pcall(function() return force.is_chunk_charted(surface, { cx, cy }) end)
          known = ok and charted or false
        end
        memo[k] = known
      end
      if known then out[#out + 1] = e end
    end
  end
  return out
end

function M.filter_visible(entities, surface, force)
  local cache, out = {}, {}
  for _, e in ipairs(entities) do
    if e.valid and M.is_visible(surface, force, e.position, cache) then out[#out + 1] = e end
  end
  return out
end

-- Entities of other forces need VISIBLE; ours and neutral ones need KNOWN.
function M.filter_perceivable(entities, surface, force)
  local known = M.filter_known(entities, surface, force)
  local cache, out = {}, {}
  for _, e in ipairs(known) do
    local other = e.force and e.force ~= force and e.force.name ~= "neutral"
    if not other or M.is_visible(surface, force, e.position, cache) then out[#out + 1] = e end
  end
  return out
end

function M.require_known(surface, force, pos, what)
  if not M.is_known(surface, force, pos) then
    error(string.format("(%.0f, %.0f) is unexplored — walk closer to see %s", pos.x, pos.y, what or "it"))
  end
end

-- Walk goals: known terrain, or unexplored terrain close enough to be the
-- next exploration step.
function M.check_walk_goal(entity, pos)
  if M.is_known(entity.surface, entity.force, pos) then return end
  local dx, dy = pos.x - entity.position.x, pos.y - entity.position.y
  local r = M.explore_radius()
  if dx * dx + dy * dy > r * r then
    error(string.format(
      "(%.0f, %.0f) is unexplored and more than %d tiles away — explore toward it in steps of up to %d tiles",
      pos.x, pos.y, r, r))
  end
end

function M.explored_count(surface, force)
  local n = 0
  for _ in pairs(explored_set(force, surface)) do n = n + 1 end
  return n
end

return M
