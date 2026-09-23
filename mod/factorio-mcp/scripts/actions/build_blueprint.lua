-- build_blueprint: build a WHOLE blueprint (an export string, or one the
-- character carries, by label) at an anchor in one job — the agent never has
-- to read the entities or copy positions. Resolution and normalization live in
-- scripts/blueprint.lua; the per-step walking/placing machinery is
-- build_plan's (same task shape, so its tick runs unchanged). Failed steps
-- (missing items, blocked ground) are reported per step like build_plan.
local companion = require("scripts.companion")
local items = require("scripts.items")
local blueprint = require("scripts.blueprint")
local build_plan = require("scripts.actions.build_plan")

local M = {}

-- Machine-generated steps, so far beyond build_plan's hand-written cap.
local MAX_ENTITIES = 1000

function M.start(task)
  companion.require_companion()
  local anchor = task.anchor
  if type(anchor) ~= "table" or type(anchor.x) ~= "number" or type(anchor.y) ~= "number" then
    error("build_blueprint requires anchor = {x, y} — where the print's top-left entity goes")
  end
  local has_string = type(task.string) == "string" and task.string ~= ""
  if not has_string and (type(task.label) ~= "string" or task.label == "") then
    error("build_blueprint requires string = <export string>, or label = <label of a carried blueprint>")
  end

  local resolved = blueprint.resolve_for_build({
    string = has_string and task.string or nil,
    label = task.label,
    book = task.book,
  })
  task.string = nil -- don't keep the (possibly huge) string in storage
  if #resolved.entities > MAX_ENTITIES then
    error(string.format(
      "'%s' has %d entities — build_blueprint takes at most %d; read it in windows and build with build_plan batches instead",
      resolved.label or task.label or "blueprint", #resolved.entities, MAX_ENTITIES))
  end

  local steps = {}
  for i, e in ipairs(resolved.entities) do
    steps[i] = {
      item = e.item,
      entity = e.name,
      position = { x = anchor.x + e.position.x, y = anchor.y + e.position.y },
      direction = e.direction,
      recipe = e.recipe,
    }
  end
  task.steps = steps
  task.label = resolved.label
  task._skipped = (#resolved.skipped > 0) and table.concat(resolved.skipped, ", ") or nil

  -- Same init contract as build_plan.start (its tick drives the task).
  task.stop_on_error = task.stop_on_error == true
  task.auto_craft = false
  task._auto_crafted = 0
  task._waiting_for_crafts = false
  task._index = 1
  task._placed = 0
  task._results = {}
  task._failures = {}
end

function M.tick(task)
  local res = build_plan.tick(task)
  if res and task._skipped then
    res.detail = (res.detail or "") .. " — skipped unknown entities: " .. task._skipped
  end
  return res
end

return M
