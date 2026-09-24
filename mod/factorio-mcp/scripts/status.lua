-- A status line per agent character for people watching.
--
-- The line has two parts:
--   * what the agent says it is doing: rpc "set_status" {text}, from the
--     MCP tool set_status;
--   * what the character is doing right now, derived from its running job
--     ("mining coal 12/60", "building 7/40 (+3 queued)", "idle").
-- It is shown under each agent's camera window (/follow-cam, /follow-cams).
-- Agents never read it back.
local companion = require("scripts.companion")

local M = {}

local MAX_LEN = 120

local function statuses()
  storage.statuses = storage.statuses or {}
  return storage.statuses
end

-- rpc "set_status" (scoped to the bound character).
function M.set(params)
  local name = companion.context()
  local text = params.text
  if text ~= nil and type(text) ~= "string" then error("set_status text must be a string") end
  if text == nil or text:match("^%s*$") then
    statuses()[name] = nil
    return { cleared = true }
  end
  text = text:gsub("[%c]+", " ")
  if #text > MAX_LEN then text = text:sub(1, MAX_LEN - 3) .. "..." end
  statuses()[name] = { text = text, tick = game.tick }
  return { status = text }
end

-- What the character is doing now, from its running job.
function M.activity(name)
  local lanes = storage.tasks and storage.tasks.by_companion
  local l = lanes and lanes[name]
  local t = l and l.active
  local queued = l and #l.queue or 0
  if not t then
    return queued > 0 and string.format("starting the next of %d queued jobs", queued) or "idle"
  end
  local s = t.type
  if t.type == "mine" then
    if t.resource then
      s = string.format("mining %s %d/%d", t.resource, (t._mine and t._mine.ops) or 0, t.count or 1)
    else
      s = "mining " .. tostring(t._entity_name or "")
    end
  elseif t.type == "build_plan" then
    s = string.format("building %d/%d", math.max((t._index or 1) - 1, 0), t.steps and #t.steps or 0)
  elseif t.type == "walk_to" and type(t.target) == "table" then
    s = string.format("walking to (%.0f, %.0f)", t.target.x or 0, t.target.y or 0)
  elseif t.type == "craft" then
    s = string.format("crafting %s x%d", tostring(t.recipe), t.count or 1)
  elseif t.type == "place" then
    s = "placing " .. tostring(t.item)
  elseif t.type == "insert" then
    s = "inserting items"
  elseif t.type == "extract" then
    s = "taking items out"
  elseif t.type == "wait_until" then
    if t.research then s = "waiting for research " .. tostring(t.research)
    elseif t.item then s = string.format("waiting for %d %s", t.count or 1, tostring(t.item))
    else s = "waiting" end
  end
  -- waiting for the engine pathfinder (any walker inside the job)
  local w = t._walk or (t._approach and t._approach.walk) or (t._aside and t._aside.walk)
  if w and (w.phase == "waiting" or w.phase == "retry_wait") and w.request_tick then
    s = s .. string.format(", waiting for a path (%d s)", math.floor((game.tick - w.request_tick) / 60))
  end
  if queued > 0 then s = s .. string.format(" (+%d queued)", queued) end
  return s
end

-- The full line: "<what the agent said> — <what it is doing>".
function M.line(name)
  local st = statuses()[name]
  local act = M.activity(name)
  if st then return st.text .. " — " .. act end
  return act
end

-- Housekeeping, run on_nth_tick (control.lua); must never raise. The status
-- is shown only under cameras (scripts/follow.lua), not above characters:
-- this removes status texts drawn by mod 0.2.6 and drops statuses of retired
-- characters.
function M.update_labels()
  pcall(function()
    if storage.status_labels then
      for _, obj in pairs(storage.status_labels) do
        if obj and obj.valid then obj.destroy() end
      end
      storage.status_labels = nil
    end
    for name in pairs(statuses()) do
      if not companion.record(name) then statuses()[name] = nil end
    end
  end)
end

return M
