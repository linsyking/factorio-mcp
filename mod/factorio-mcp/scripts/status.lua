-- A status line per agent character for people watching.
--
-- The line has two parts:
--   * what the agent says it is doing: rpc "set_status" {text}, from the
--     MCP tool set_status;
--   * what the character is doing right now, derived from its running job
--     ("mining coal 12/60", "building 7/40 (+3 queued)", "idle").
-- It is drawn under the character's name label and shown under each camera
-- of /follow-cam and /follow-cams. Agents never read it back.
local companion = require("scripts.companion")

local M = {}

local MAX_LEN = 120
local LABEL_OFFSET = { 0, -2.2 } -- just under the name label (companion.lua draws it at -2.9)

local function statuses()
  storage.statuses = storage.statuses or {}
  return storage.statuses
end

local function labels()
  storage.status_labels = storage.status_labels or {}
  return storage.status_labels
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

-- Keep the floating status text under every agent's name label current.
-- Runs on_nth_tick (control.lua); must never raise.
function M.update_labels()
  pcall(function()
    local ls = labels()
    for _, name in ipairs(companion.names()) do
      local body = companion.get(name)
      local obj = ls[name]
      if body then
        local text = M.line(name)
        local ok_target = obj and obj.valid and obj.target and obj.target.entity == body
        if ok_target then
          if obj.text ~= text then obj.text = text end
        else
          if obj and obj.valid then obj.destroy() end
          ls[name] = rendering.draw_text({
            text = text, surface = body.surface, target = { entity = body, offset = LABEL_OFFSET },
            color = { 0.92, 0.92, 0.92 }, scale = 0.9, alignment = "center", scale_with_zoom = true,
          })
        end
      elseif obj then
        if obj.valid then obj.destroy() end
        ls[name] = nil
      end
    end
    -- retired characters
    for name, obj in pairs(ls) do
      if not companion.record(name) then
        if obj.valid then obj.destroy() end
        ls[name] = nil
        statuses()[name] = nil
      end
    end
  end)
end

return M
