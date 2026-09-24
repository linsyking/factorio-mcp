-- Who last changed an entity, and when. The fleet is ONE force and the mod is
-- policy-free: any agent may rotate, replace or re-recipe a building another
-- agent placed. So when a machine is found facing the wrong way (fleet watch
-- #61), inspect_entity says which character and job last touched it —
-- "changed by coal (job #20625) at tick 3527665: rotated to face west".
--
-- Only the LAST change per entity is kept (that is what an audit needs), in a
-- bounded table pruned FIFO. Entries for destroyed entities are dropped the
-- same way; nothing here is authoritative, it is a note.
local companion = require("scripts.companion")

local M = {}

local MAX_ENTITIES = 4096

local function store()
  return storage.provenance
end

-- Record that `task` (a job, with .companion and .id) did `action` to `e`.
-- Safe to call on anything: entities without a unit_number are skipped.
function M.record(e, action, task)
  if not (e and e.valid and e.unit_number and task) then return end
  local s = store()
  local un = e.unit_number
  if s.by_unit[un] == nil then
    s.order[#s.order + 1] = un
    if #s.order > MAX_ENTITIES then s.by_unit[table.remove(s.order, 1)] = nil end
  end
  s.by_unit[un] = {
    action = action,
    by = task.companion or companion.context() or "?",
    job = task.id,
    tick = game.tick,
  }
end

-- The note inspect_entity shows for this entity, or nil when no recorded
-- change (the entity predates this table, or only the engine touched it).
function M.note(e)
  if not (e and e.valid and e.unit_number) then return nil end
  local p = store().by_unit[e.unit_number]
  if not p then return nil end
  return string.format("%s by %s (job #%d) at tick %d", p.action, p.by, p.job, p.tick)
end

return M
