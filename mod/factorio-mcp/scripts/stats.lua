-- production_stats: the force's item AND fluid production/consumption on the
-- character's surface over a time window — the same data a player sees in
-- the production statistics window (force-wide, so no fog of war applies).
--
-- params: { window = "5s"|"1m"|"10m"|"1h"|"10h"|"50h"|"250h"|"1000h" (default "1m"),
--           names = {"iron-plate", "water", ...}?  (default: everything seen),
--           top = n? (default 20, max 200) }
-- Rates are per minute, computed from the window's total count.
local companion = require("scripts.companion")

local M = {}

local WINDOWS = {
  ["5s"] = { index = "five_seconds", minutes = 5 / 60 },
  ["1m"] = { index = "one_minute", minutes = 1 },
  ["10m"] = { index = "ten_minutes", minutes = 10 },
  ["1h"] = { index = "one_hour", minutes = 60 },
  ["10h"] = { index = "ten_hours", minutes = 600 },
  ["50h"] = { index = "fifty_hours", minutes = 3000 },
  ["250h"] = { index = "two_hundred_fifty_hours", minutes = 15000 },
  ["1000h"] = { index = "one_thousand_hours", minutes = 60000 },
}

local function round2(v) return math.floor(v * 100 + 0.5) / 100 end

local function window_total(stats, name, category, precision)
  local n = 0
  pcall(function()
    n = stats.get_flow_count({ name = name, category = category, precision_index = precision, count = true })
  end)
  return n
end

local function collect(stats, kind, precision, minutes, wanted, out)
  local names = {}
  if wanted then
    for _, n in ipairs(wanted) do names[#names + 1] = n end
  else
    local seen = {}
    for n in pairs(stats.input_counts) do if not seen[n] then seen[n] = true; names[#names + 1] = n end end
    for n in pairs(stats.output_counts) do if not seen[n] then seen[n] = true; names[#names + 1] = n end end
  end
  for _, name in ipairs(names) do
    local produced = window_total(stats, name, "input", precision)
    local consumed = window_total(stats, name, "output", precision)
    local total_p = stats.input_counts[name] or 0
    local total_c = stats.output_counts[name] or 0
    if wanted or produced > 0 or consumed > 0 or total_p > 0 or total_c > 0 then
      out[#out + 1] = {
        name = name,
        kind = kind,
        produced_per_min = round2(produced / minutes),
        consumed_per_min = round2(consumed / minutes),
        net_per_min = round2((produced - consumed) / minutes),
        produced_all_time = math.floor(total_p),
        consumed_all_time = math.floor(total_c),
      }
    end
  end
end

-- The engine records no production for script mining (LuaEntity.mine) or for
-- crafting by a character without a player, while it does for a real
-- player's hand-mining and hand-crafting. Record those flows explicitly so
-- the statistics match what a player would see.
function M.record_produced(character, name, count)
  if not (character and character.valid) or count <= 0 then return end
  pcall(function()
    character.force.get_item_production_statistics(character.surface).on_flow(name, count)
  end)
end

function M.production_stats(params)
  local c = companion.require_companion()
  local wname = params.window or "1m"
  local w = WINDOWS[wname]
  if not w then error("window must be one of 5s, 1m, 10m, 1h, 10h, 50h, 250h, 1000h") end
  local precision = defines.flow_precision_index[w.index]

  local wanted_items, wanted_fluids
  if type(params.names) == "table" and #params.names > 0 then
    wanted_items, wanted_fluids = {}, {}
    for _, n in ipairs(params.names) do
      if prototypes.fluid[n] then
        wanted_fluids[#wanted_fluids + 1] = n
      elseif prototypes.item[n] then
        wanted_items[#wanted_items + 1] = n
      else
        error("no item or fluid called '" .. tostring(n) .. "'")
      end
    end
  end

  local rows = {}
  local kind = params.kind or "both"
  if kind == "both" or kind == "item" then
    collect(c.force.get_item_production_statistics(c.surface), "item", precision, w.minutes, wanted_items, rows)
  end
  if kind == "both" or kind == "fluid" then
    collect(c.force.get_fluid_production_statistics(c.surface), "fluid", precision, w.minutes, wanted_fluids, rows)
  end

  table.sort(rows, function(a, b)
    local ra = math.max(a.produced_per_min, a.consumed_per_min)
    local rb = math.max(b.produced_per_min, b.consumed_per_min)
    if ra ~= rb then return ra > rb end
    return a.produced_all_time > b.produced_all_time
  end)
  local top = math.max(1, math.min(tonumber(params.top) or 20, 200))
  local out = {}
  for i = 1, math.min(#rows, top) do out[i] = rows[i] end
  return { window = wname, surface = c.surface.name, rows = out, total_rows = #rows }
end

return M
