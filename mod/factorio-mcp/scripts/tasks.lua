-- Job queue + per-tick dispatcher. RCON calls enqueue; execution happens in
-- on_tick (always registered, early-exit when idle). Each character has its
-- own lane, so different characters' jobs run in parallel. A character can
-- only see and cancel its own jobs. Every finished job (except quiet plan
-- steps and cancellations) is also logged as a job_done/job_failed event.
local companion = require("scripts.companion")
local events = require("scripts.events")
local walk = require("scripts.actions.walk")
local follow = require("scripts.actions.follow")
local mine = require("scripts.actions.mine")
local build = require("scripts.actions.build")
local craft = require("scripts.actions.craft")
local transfer = require("scripts.actions.transfer")
local refuel = require("scripts.actions.refuel")
local drive = require("scripts.actions.drive")
local build_plan = require("scripts.actions.build_plan")
local deconstruct = require("scripts.actions.deconstruct")
local fight = require("scripts.actions.fight")

local M = {}

local function clean(err)
  return (tostring(err):gsub("^__[%w%-_]+__/[%w%-_/%.]+:%d+: ", ""))
end

local RECORD_TTL_TICKS = 5 * 60 * 60 -- keep finished-task records for 5 minutes
local PRUNE_INTERVAL_TICKS = 3600

local runners = {
  walk_to = walk,
  follow_player = follow,
  mine = mine,
  place = build.place,
  rotate = build.rotate,
  set_recipe = build.set_recipe,
  craft = craft,
  insert = transfer.insert,
  extract = transfer.extract,
  keep_fueled = refuel,
  drive_to = drive,
  defend_area = require("scripts.actions.defend"),
  build_plan = build_plan,
  build_blueprint = require("scripts.actions.build_blueprint"),
  deconstruct = deconstruct,
  fight = fight,
  wait_until = require("scripts.actions.wait_until"),
}

-- One lane (queue + active) per companion; tasks in different lanes run in
-- the same tick, so companions genuinely work in parallel.
local function lane(name)
  local lanes = storage.tasks.by_companion
  local l = lanes[name]
  if not l then
    l = { queue = {}, active = nil }
    lanes[name] = l
  end
  return l
end

local function stop_body()
  local c = companion.get()
  if c then
    c.walking_state = { walking = false }
    c.mining_state = { mining = false }
    pcall(function()
      c.shooting_state = { state = defines.shooting.not_shooting }
    end)
  end
end

-- finish() runs with the companion context already set to the task's owner.
local function record(task, status, detail)
  storage.tasks.records[task.id] = {
    status = status,
    detail = detail or "",
    finished_tick = game.tick,
    companion = task.companion,
    type = task.type,
  }
end

local function finish(task, status, detail)
  if task._pick_note then detail = (detail or "") .. " — NOTE: " .. task._pick_note end
  record(task, status, detail)
  local l = lane(task.companion or companion.DEFAULT)
  if l.active and l.active.id == task.id then
    l.active = nil
  end
  stop_body()

  -- A failed step of a plan takes its dependent siblings down with it: later
  -- steps of the same chain are cancelled so the brain gets ONE failure event
  -- instead of a cascade ("insert the plates" can't work if the craft failed).
  -- The chain is also remembered as failed: a fast failure can beat the
  -- remaining enqueue RPCs to the punch, so late arrivals of the same chain
  -- are cancelled at enqueue time (see M.enqueue).
  -- An optional step (a fuel top-up, say) reports its failure but doesn't
  -- take the rest of the chain down; it is still cancelled like any other
  -- step when something before it fails.
  if status == "failed" and task.chain and not task.optional then
    storage.tasks.failed_chains = storage.tasks.failed_chains or {}
    storage.tasks.failed_chains[task.chain] = game.tick
    local l2 = lane(task.companion or companion.DEFAULT)
    local kept = {}
    for _, q in ipairs(l2.queue) do
      if q.chain == task.chain then
        record(q, "cancelled", "skipped: an earlier step of the same plan failed")
      else
        kept[#kept + 1] = q
      end
    end
    l2.queue = kept
  end

  -- Log the outcome so an agent waiting on events hears about it. `quiet`
  -- suppresses the success event (run_plan marks every step but the last
  -- quiet, so a whole plan reports once). Failures always report;
  -- cancellations stay silent.
  pcall(function()
    local who = task.companion or companion.DEFAULT
    if status == "done" and not task.quiet then
      events.push("job_done", "job #" .. task.id .. " (" .. task.type .. ") done: " .. (detail or "done"),
        { companion = who, job_id = task.id })
    elseif status == "failed" and task.optional then
      events.push("optional_job_failed", "optional job #" .. task.id .. " (" .. task.type .. ") failed, the rest "
        .. "of the queue goes on: " .. (detail or "no detail"), { companion = who, job_id = task.id })
    elseif status == "failed" then
      events.push("job_failed", "job #" .. task.id .. " (" .. task.type .. ") FAILED: " .. (detail or "no detail"),
        { companion = who, job_id = task.id })
    end
  end)
end

local function cancel_lane(name)
  local l = lane(name)
  local n = 0
  for _, q in ipairs(l.queue) do
    record(q, "cancelled", "")
    n = n + 1
  end
  l.queue = {}
  if l.active then
    companion.set_context(name)
    finish(l.active, "cancelled", "")
    n = n + 1
  end
  return n
end

function M.enqueue(params)
  local task = params.task
  if type(task) ~= "table" or not runners[task.type] then
    error("unknown task type: " .. tostring(type(task) == "table" and task.type or task))
  end
  local name = companion.context()
  companion.require_companion(name)
  -- A client that lost the reply to an enqueue (dropped RCON connection) sends
  -- the same request_id again; answer with the job the first attempt made.
  local rid = params.request_id and tostring(params.request_id)
  if rid then
    storage.tasks.request_ids = storage.tasks.request_ids or {}
    local prev = storage.tasks.request_ids[rid]
    if prev then return { task_id = prev.task_id, companion = name, cancelled = prev.cancelled, duplicate = true } end
  end
  if params.replace then
    cancel_lane(name)
    companion.set_context(name)
  end
  local t = storage.tasks
  task.id = t.next_id
  t.next_id = t.next_id + 1
  task.status = "queued"
  task.companion = name
  task.enqueued_tick = game.tick
  task.background = params.background == true
  task.quiet = params.quiet == true
  task.optional = params.optional == true
  if params.chain ~= nil then task.chain = tostring(params.chain) end

  -- Late arrival of an already-failed plan: cancel silently right here (the
  -- failure that killed the chain already produced its one event).
  local fc = storage.tasks.failed_chains
  if task.chain and fc and fc[task.chain] then
    record(task, "cancelled", "skipped: an earlier step of the same plan failed")
    if rid then storage.tasks.request_ids[rid] = { task_id = task.id, cancelled = true, tick = game.tick } end
    return { task_id = task.id, companion = name, cancelled = true }
  end

  local l = lane(name)
  l.queue[#l.queue + 1] = task
  if rid then storage.tasks.request_ids[rid] = { task_id = task.id, tick = game.tick } end
  return { task_id = task.id, companion = name }
end

local function not_yours(id)
  error("job #" .. id .. " doesn't belong to your character")
end

function M.get(params)
  local id = tonumber(params.task_id)
  if not id then error("get_task requires task_id") end
  local me = companion.context()
  for name, l in pairs(storage.tasks.by_companion) do
    if l.active and l.active.id == id then
      if name ~= me then not_yours(id) end
      return { status = "running", detail = "", type = l.active.type }
    end
    for _, q in ipairs(l.queue) do
      if q.id == id then
        if name ~= me then not_yours(id) end
        return { status = "queued", detail = "", type = q.type }
      end
    end
  end
  local rec = storage.tasks.records[id]
  if rec then
    if rec.companion and rec.companion ~= me then not_yours(id) end
    return { status = rec.status, detail = rec.detail, type = rec.type }
  end
  error("unknown job #" .. id .. " (finished jobs are forgotten after 5 minutes)")
end

-- Own lane only: the active job, the queue, and recently finished jobs.
function M.list(params)
  local me = companion.context()
  local l = lane(me)
  local out = { queued = {}, recent = {} }
  if l.active then
    out.active = { id = l.active.id, type = l.active.type,
      running_s = math.floor((game.tick - (l.active.started_tick or game.tick)) / 60) }
  end
  for _, q in ipairs(l.queue) do out.queued[#out.queued + 1] = { id = q.id, type = q.type } end
  local recent = {}
  for id, rec in pairs(storage.tasks.records) do
    if rec.companion == me then
      recent[#recent + 1] = { id = id, type = rec.type, status = rec.status, detail = rec.detail,
        ago_s = math.floor((game.tick - rec.finished_tick) / 60) }
    end
  end
  table.sort(recent, function(a, b) return a.id > b.id end)
  local limit = math.max(1, math.min(tonumber(params.limit) or 10, 50))
  for i = 1, math.min(#recent, limit) do out.recent[i] = recent[i] end
  return out
end

function M.cancel(params)
  local me = companion.context()
  if params.all then return { cancelled = cancel_lane(me) } end
  local id = tonumber(params.task_id)
  if not id then error("cancel requires task_id or all=true") end
  local l = lane(me)
  if l.active and l.active.id == id then
    finish(l.active, "cancelled", "")
    return { cancelled = 1 }
  end
  for i, q in ipairs(l.queue) do
    if q.id == id then
      table.remove(l.queue, i)
      record(q, "cancelled", "")
      return { cancelled = 1 }
    end
  end
  for name, other in pairs(storage.tasks.by_companion) do
    if name ~= me then
      if other.active and other.active.id == id then not_yours(id) end
      for _, q in ipairs(other.queue) do
        if q.id == id then not_yours(id) end
      end
    end
  end
  local rec = storage.tasks.records[id]
  if rec and rec.companion ~= me then not_yours(id) end
  return { cancelled = 0 }
end

-- Serializable summary of a companion's active task for get_state.
function M.active_summary(name)
  local a = lane(name or companion.context()).active
  if not a then return nil end
  return { id = a.id, type = a.type, status = "running" }
end

function M.queue_length(name)
  return #lane(name or companion.context()).queue
end

local function prune_records()
  local t = storage.tasks
  for id, rec in pairs(t.records) do
    if game.tick - rec.finished_tick > RECORD_TTL_TICKS then
      t.records[id] = nil
    end
  end
  for rid, entry in pairs(t.request_ids or {}) do
    if game.tick - entry.tick > RECORD_TTL_TICKS then t.request_ids[rid] = nil end
  end
  for chain, tick in pairs(t.failed_chains or {}) do
    if game.tick - tick > RECORD_TTL_TICKS then
      t.failed_chains[chain] = nil
    end
  end
end

local function step_lane(name, l)
  local task = l.active
  if not task then
    if #l.queue == 0 then return end
    task = table.remove(l.queue, 1)
    task.status = "running"
    task.started_tick = game.tick
    l.active = task
    local ok, err = pcall(runners[task.type].start, task)
    if not ok then
      finish(task, "failed", clean(err))
      return
    end
  end

  local ok, result = pcall(runners[task.type].tick, task)
  if not ok then
    finish(task, "failed", clean(result))
  elseif result then
    finish(task, result.status, result.detail)
  end
end

function M.on_tick()
  if game.tick % PRUNE_INTERVAL_TICKS == 0 then
    prune_records()
  end
  for name, l in pairs(storage.tasks.by_companion) do
    if l.active or #l.queue > 0 then
      companion.set_context(name)
      step_lane(name, l)
    end
  end
  companion.set_context(nil)
end

return M
