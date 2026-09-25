-- start_research: queue a technology on the companion's force.
-- list_technologies: the whole tech tree — internal name (exactly what
--   start_research takes), status, prerequisites, research bill — plus the
--   live research queue in order. Before this the fleet discovered techs
--   only by name-probe or by start_research's error text, so the
--   unlocked-but-unresearched set was invisible and leverage techs sat
--   undeveloped while the queue ran the critical path.
-- cancel_research: remove a QUEUED, not-yet-started technology from the
--   queue. The head — the research in progress — is refused: cancelling it
--   would discard its progress.
local companion = require("scripts.companion")

local M = {}

local function force_of_caller()
  local c = companion.get()
  return (c and c.force) or game.forces.player
end

-- Display label derived from the internal name: the Lua API has no
-- synchronous locale resolve server-side, so this is the kebab name
-- prettified ("fast-inserter" -> "Fast inserter"). The internal name is
-- authoritative and exactly what start_research takes.
local function label_of(name)
  local s = (name:gsub("%-", " "))
  return (s:gsub("^%l", string.upper))
end

function M.start_research(params)
  local name = params.technology
  if type(name) ~= "string" or name == "" then
    error('start_research needs a technology name, e.g. {"technology": "logistics"}')
  end

  local force = force_of_caller()

  local ok, tech = pcall(function() return force.technologies[name] end)
  if not ok or not tech then
    error("unknown technology: " .. name)
  end
  if tech.researched then
    error("already researched: " .. name)
  end
  for _, queued in ipairs(force.research_queue or {}) do
    if queued.name == name then
      error(name .. " is already in the research queue")
    end
  end
  if not force.add_research(name) then
    -- Most common cause: an unresearched trigger-tech prerequisite (2.0 early
    -- techs unlock by doing things in the world, not in a lab).
    local missing = {}
    for prereq_name, prereq in pairs(tech.prerequisites) do
      if not prereq.researched then
        local is_trigger = prereq.prototype.research_trigger ~= nil
        missing[#missing + 1] = prereq_name
          .. (is_trigger and " (unlocks via an in-game action, not lab research)" or "")
      end
    end
    if #missing > 0 then
      error("can't queue " .. name .. " yet — missing prerequisites: " .. table.concat(missing, ", "))
    end
    error("could not queue " .. name .. " — the game refused it")
  end

  return { queued = true, technology = name }
end

local STATUS_LIST = { "researched", "in-progress", "queued", "available", "trigger", "locked", "all" }
local STATUS = {}
for _, s in ipairs(STATUS_LIST) do STATUS[s] = true end

-- Safe reads: LuaObjects raise on unknown members, and 2.0.77 must survive
-- every field this touches (each is pcall-guarded; on refusal the default
-- degrades the output honestly instead of failing the whole read).
local function safe(fn, default)
  local ok, v = pcall(fn)
  if ok then return v end
  return default
end

function M.list_technologies(params)
  params = params or {}
  local want = params.status or "available"
  if not STATUS[want] then
    error("status must be one of: " .. table.concat(STATUS_LIST, ", "))
  end
  local search = type(params.search) == "string" and params.search or ""
  search = search:lower()
  if search == "" then search = nil end

  local force = force_of_caller()

  -- live queue, in order ([1] is the research in progress)
  local queue, qpos = {}, {}
  safe(function()
    for i, t in ipairs(force.research_queue or {}) do
      qpos[t.name] = i
      queue[#queue + 1] = t.name
    end
  end)
  local current_name = safe(function()
    local cr = force.current_research
    return cr and cr.name or nil
  end, nil)
  local progress = safe(function() return force.research_progress or 0 end, 0)

  local counts = { researched = 0, ["in-progress"] = 0, queued = 0, available = 0, trigger = 0, locked = 0 }
  local techs = {}
  for name, tech in pairs(force.technologies) do
    local status
    if tech.researched then status = "researched"
    elseif name == current_name then status = "in-progress"
    elseif qpos[name] then status = "queued"
    else
      -- trigger techs unlock by doing things in the world, not in a lab
      local is_trigger = safe(function() return tech.prototype.research_trigger ~= nil end, false)
      if is_trigger then status = "trigger"
      elseif tech.enabled then status = "available"
      else status = "locked" end
    end
    counts[status] = counts[status] + 1

    if want == "all" or want == status then
      local hit = true
      if search then hit = name:lower():find(search, 1, true) ~= nil end
      if hit then
        local prereqs, missing = {}, {}
        for pname, p in pairs(tech.prerequisites or {}) do
          prereqs[#prereqs + 1] = pname
          if not p.researched then missing[#missing + 1] = pname end
        end
        table.sort(prereqs)
        table.sort(missing)

        -- total bill: per-unit ingredients x unit count
        local count = safe(function() return tech.research_unit_count or 0 end, 0)
        local bill = {}
        for _, ing in ipairs(tech.research_unit_ingredients or {}) do
          bill[ing.name] = (ing.amount or 0) * count
        end
        -- per-unit energy: 60 J per second of lab work at speed 1
        local energy = safe(function() return tech.research_unit_energy or 0 end, 0)
        local level = safe(function() return tech.level or 1 end, 1)
        local infinite = safe(function() return tech.research_unit_count_formula ~= nil end, false)
        local order = safe(function()
          return tech.order or (tech.prototype and tech.prototype.order) or name
        end, name)

        techs[#techs + 1] = {
          name = name, label = label_of(name), status = status,
          order = order, level = level, infinite = infinite,
          prereqs = prereqs, missing = missing, bill = bill,
          unit_energy = energy, unit_time_s = math.floor(energy / 60 + 0.5),
        }
      end
    end
  end
  table.sort(techs, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.name < b.name
  end)

  return {
    filter = want, search = search,
    current = current_name, progress = math.floor(progress * 100 + 0.5),
    queue = queue, counts = counts, techs = techs,
  }
end

function M.cancel_research(params)
  local name = params.technology
  if type(name) ~= "string" or name == "" then
    error('cancel_research needs a technology name, e.g. {"technology": "steel-processing"}')
  end

  local force = force_of_caller()

  local ok, tech = pcall(function() return force.technologies[name] end)
  if not ok or not tech then
    error("unknown technology: " .. name)
  end

  -- the research in progress is refused outright, wherever it sits in the
  -- queue (normally [1]): removing it would discard its progress
  local current_name = safe(function()
    local cr = force.current_research
    return cr and cr.name
  end, nil)
  if current_name == name then
    error(name .. " is the research in progress — cancelling it would discard its progress; "
      .. "this removes queued, not-yet-started techs only")
  end

  local queue = {}
  safe(function()
    for _, t in ipairs(force.research_queue or {}) do queue[#queue + 1] = t end
  end)

  local idx
  for i, t in ipairs(queue) do
    if t.name == name then idx = i break end
  end
  if not idx then
    if tech.researched then
      error("already researched: " .. name)
    end
    error(name .. " is not in the research queue")
  end

  local head_before = queue[1] and queue[1].name
  local progress_before = safe(function() return force.research_progress or 0 end, 0)

  -- the API has no remove-one: write the whole queue back minus this tech.
  -- The head stays the head, so the research in progress keeps running.
  local new_queue = {}
  for i, t in ipairs(queue) do
    if i ~= idx then new_queue[#new_queue + 1] = t end
  end
  local wrote, werr = pcall(function() force.research_queue = new_queue end)
  if not wrote then
    error("the engine refused the queue rewrite: " .. tostring(werr))
  end

  -- what the queue actually is now (the engine may drop entries it won't take)
  local after = {}
  safe(function()
    for _, t in ipairs(force.research_queue or {}) do after[#after + 1] = t.name end
  end)
  local in_after = {}
  for _, n in ipairs(after) do in_after[n] = true end
  local dropped = {}
  for _, t in ipairs(new_queue) do
    if not in_after[t.name] then dropped[#dropped + 1] = t.name end
  end

  -- guard the head's progress against a rewrite that resets it: no tick
  -- passes inside one RPC, so a regressed progress is the rewrite's doing
  local head_now = safe(function()
    local cr = force.current_research
    return cr and cr.name
  end, nil)
  local restored = false
  if head_before and head_now == head_before then
    local progress_now = safe(function() return force.research_progress or 0 end, 0)
    if progress_now < progress_before then
      restored = safe(function()
        force.research_progress = progress_before
        return true
      end, false)
    end
  end

  local out = { removed = name, queue = after }
  if #dropped > 0 then out.dropped = dropped end
  if restored then out.note = "research progress restored after the queue rewrite" end
  return out
end

return M
