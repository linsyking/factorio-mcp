-- Offline tests for scripts/provenance.lua (#61): inspect_entity's "last
-- changed by" audit note. Uses the real state.lua init for storage.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

_G.game = { tick = 100 }
_G.storage = {}
package.loaded["scripts.companion"] = { context = function() return "fallback" end }
require("scripts.state").init()

local provenance = require("scripts.provenance")

local e = { valid = true, unit_number = 42 }
provenance.record(e, "rotated to face west", { companion = "coal", id = 20625 })
check(provenance.note(e) == "rotated to face west by coal (job #20625) at tick 100",
  "provenance: the note names the action, character, job and tick")

-- the last change wins
provenance.record(e, "set recipe to plastic-bar", { companion = "oil", id = 7 })
check(provenance.note(e) == "set recipe to plastic-bar by oil (job #7) at tick 100",
  "provenance: only the last change per entity is kept")

-- a task without a companion falls back to the context (the running lane)
provenance.record({ valid = true, unit_number = 43 }, "placed", { id = 8 })
check(provenance.note({ valid = true, unit_number = 43 }) == "placed by fallback (job #8) at tick 100",
  "provenance: the context character is used when the task carries none")

-- unknown, invalid or unit-less entities have no note
check(provenance.note({ valid = true, unit_number = 999 }) == nil, "provenance: no note for an untouched entity")
check(provenance.note(nil) == nil and provenance.note({ valid = false }) == nil,
  "provenance: nil and invalid entities are safe")
provenance.record({ valid = true }, "placed", { companion = "x", id = 1 })
check(true, "provenance: recording without a unit_number does not error")

-- the table is bounded: the oldest entity's entry is dropped FIFO
local first = { valid = true, unit_number = 1 }
provenance.record(first, "placed", { companion = "x", id = 1 })
for i = 2, 5000 do
  provenance.record({ valid = true, unit_number = i }, "placed", { companion = "x", id = i })
end
check(provenance.note(first) == nil, "provenance: bounded — the oldest entry is evicted")
check(provenance.note({ valid = true, unit_number = 5000 }) ~= nil, "provenance: the newest entry survives")
check(#storage.provenance.order == 4096, "provenance: the order list stays at the cap")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
