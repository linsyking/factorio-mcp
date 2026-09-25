-- Offline tests for the tech-tree tools (research.lua, 0.2.21):
-- list_technologies (statuses, queue snapshot, bills, filters, search) and
-- cancel_research (remove a queued-not-started tech; the in-progress one is
-- refused; queue rewrite keeps the head and its progress). The fleet had no
-- view of the unlocked-but-unresearched set before — names were discovered
-- only by probe or by start_research's error text.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

-- ---------------------------------------------------------------- stubs
storage = {}

local function tech(name, o)
  o = o or {}
  return {
    name = name,
    researched = o.researched or false,
    enabled = o.enabled or false,
    level = o.level or 1,
    order = o.order or name,
    prerequisites = o.prerequisites or {},
    research_unit_ingredients = o.research_unit_ingredients or {},
    research_unit_count = o.research_unit_count or 0,
    research_unit_energy = o.research_unit_energy or 0,
    research_unit_count_formula = o.formula,
    prototype = { research_trigger = o.trigger },
  }
end

local t_logistics = tech("logistics", { researched = true, enabled = true })
local t_steel = tech("steel-processing", { enabled = true,
  prerequisites = { logistics = t_logistics },
  research_unit_ingredients = { { name = "automation-science-pack", amount = 1 } },
  research_unit_count = 100, research_unit_energy = 600 })
local t_fast = tech("fast-inserter", { enabled = true,
  prerequisites = { ["steel-processing"] = t_steel },
  research_unit_ingredients = {
    { name = "automation-science-pack", amount = 1 },
    { name = "logistic-science-pack", amount = 1 } },
  research_unit_count = 75, research_unit_energy = 900 })
local t_mining = tech("mining-productivity-bonus-1", { enabled = true, level = 3, formula = "L*250",
  research_unit_ingredients = { { name = "automation-science-pack", amount = 1 } },
  research_unit_count = 250, research_unit_energy = 600 })
local t_logi2 = tech("logistics-2", { enabled = true,
  prerequisites = { logistics = t_logistics },
  research_unit_ingredients = { { name = "automation-science-pack", amount = 1 } },
  research_unit_count = 50, research_unit_energy = 600 })
local t_oil = tech("oil-processing", { enabled = true,
  prerequisites = { ["steel-processing"] = t_steel } })
local t_auto = tech("automation", { enabled = true, trigger = { type = "craft-item" } })
local t_eed2 = tech("electric-energy-distribution-2", { enabled = false,
  prerequisites = { ["steel-processing"] = t_steel } })

local added = {}
local function fresh_force(queue, current, progress)
  added = {}
  return {
    technologies = {
      logistics = t_logistics, ["steel-processing"] = t_steel, ["fast-inserter"] = t_fast,
      ["mining-productivity-bonus-1"] = t_mining, ["logistics-2"] = t_logi2,
      ["oil-processing"] = t_oil, automation = t_auto,
      ["electric-energy-distribution-2"] = t_eed2,
    },
    research_queue = queue or { t_logi2, t_oil },
    current_research = current == nil and t_logi2 or current,
    research_progress = progress or 0.4,
    add_research = function(n) added[#added + 1] = n return true end,
  }
end

game = { forces = { player = fresh_force() } }

local research = require("scripts.research")

local function err_of(fn)
  local ok, e = pcall(fn)
  if ok then return nil end
  return tostring(e)
end

-- ------------------------------------------------------- list_technologies

do -- default filter: available (unlocked but unresearched), queue on top
  local r = research.list_technologies({})
  check(r.current == "logistics-2", "current research reported")
  check(r.progress == 40, "research progress as percent")
  check(r.queue[1] == "logistics-2" and r.queue[2] == "oil-processing", "live queue order")
  check(r.counts.researched == 1 and r.counts.available == 3 and r.counts.queued == 1
    and r.counts["in-progress"] == 1 and r.counts.trigger == 1 and r.counts.locked == 1,
    "status counts")
  check(#r.techs == 3, "only available techs listed by default")
  check(r.techs[1].name == "fast-inserter" and r.techs[2].name == "mining-productivity-bonus-1"
    and r.techs[3].name == "steel-processing", "listed in tech-tree order")
  local steel = r.techs[3]
  check(steel.label == "Steel processing", "display label prettified from the name")
  check(steel.bill["automation-science-pack"] == 100, "bill = per-unit ingredient x unit count")
  check(steel.unit_time_s == 10, "unit time = unit energy / 60")
  check(#steel.missing == 0, "available tech has no missing prerequisites")
  local fast = r.techs[1]
  check(fast.missing[1] == "steel-processing", "missing prerequisites named")
  check(fast.bill["logistic-science-pack"] == 75, "multi-pack bill")
  check(fast.unit_time_s == 15, "fast-inserter unit time")
  local mining = r.techs[2]
  check(mining.infinite and mining.level == 3, "infinite tech flagged with its level")
end

do -- search substring, status=all
  local r = research.list_technologies({ status = "all", search = "FAST" })
  check(r.filter == "all" and r.search == "fast", "filter and search echoed")
  check(#r.techs == 1 and r.techs[1].name == "fast-inserter", "search matches case-insensitively")
end

do -- locked shows what it needs
  local r = research.list_technologies({ status = "locked" })
  check(#r.techs == 1 and r.techs[1].name == "electric-energy-distribution-2", "locked techs")
  check(r.techs[1].missing[1] == "steel-processing", "locked tech names its missing prerequisite")
end

do -- every other status filter
  check(research.list_technologies({ status = "researched" }).techs[1].name == "logistics", "researched filter")
  check(research.list_technologies({ status = "queued" }).techs[1].name == "oil-processing", "queued filter")
  check(research.list_technologies({ status = "in-progress" }).techs[1].name == "logistics-2", "in-progress filter")
  check(research.list_technologies({ status = "trigger" }).techs[1].name == "automation", "trigger filter (unlock by doing)")
  local e = err_of(function() research.list_technologies({ status = "done" }) end)
  check(e and e:find("status must be one of"), "invalid status lists the valid values")
end

-- --------------------------------------------------------- cancel_research

do -- removes a queued tech, keeps the head
  local r = research.cancel_research({ technology = "oil-processing" })
  check(r.removed == "oil-processing", "reports the removed tech")
  check(#r.queue == 1 and r.queue[1] == "logistics-2", "head stays, queue rewritten")
  check(r.dropped == nil, "nothing dropped by the engine")
  check(r.note == nil, "no progress note when progress is untouched")
end

do -- the research in progress is refused
  local e = err_of(function() research.cancel_research({ technology = "logistics-2" }) end)
  check(e and e:find("research in progress") and e:find("discard its progress"),
    "in-progress tech refused with the reason")
end

do -- not queued / already researched / unknown
  local e = err_of(function() research.cancel_research({ technology = "steel-processing" }) end)
  check(e and e:find("not in the research queue"), "available tech is not in the queue")
  e = err_of(function() research.cancel_research({ technology = "logistics" }) end)
  check(e and e:find("already researched"), "researched tech reported")
  e = err_of(function() research.cancel_research({ technology = "nope" }) end)
  check(e and e:find("unknown technology"), "unknown tech reported")
end

do -- a rewrite that resets the head's progress gets it restored
  local real = fresh_force({ t_logi2, t_oil })
  local force = setmetatable({}, {
    __index = function(_, k) return real[k] end,
    __newindex = function(t, k, v)
      rawset(real, k, v)
      if k == "research_queue" then real.research_progress = 0 end -- the engine resets head progress
    end,
  })
  game = { forces = { player = force } }
  local r = research.cancel_research({ technology = "oil-processing" })
  check(r.removed == "oil-processing", "proxy force: removal done")
  check(r.note and r.note:find("progress restored"), "progress restored after the rewrite")
  check(force.research_progress == 0.4, "progress value back")
end

-- ---------------------------------------------------------- start_research

do -- regression: queueing still works and still refuses duplicates
  game = { forces = { player = fresh_force() } }
  local r = research.start_research({ technology = "steel-processing" })
  check(r.queued and r.technology == "steel-processing", "start_research queues")
  check(added[1] == "steel-processing", "add_research called")
  local e = err_of(function() research.start_research({ technology = "logistics-2" }) end)
  check(e and e:find("already in the research queue"), "queued tech refused on duplicate queue")
end

print(failures == 0 and "research_test: all ok" or ("research_test: " .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
