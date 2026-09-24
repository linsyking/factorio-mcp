-- Offline tests for the equipment read (equipment.lua, 0.2.18): summary.gun
-- lists EVERY gun slot — the engine auto-fills an empty gun slot from a
-- crafted gun (the same behavior that lands crafted ammo in the ammo slot,
-- ledger #36), and a gun in a second slot was invisible to check_inventory
-- and get_state until an explicit equip "resolved" it (soldier's crafted SMG).
-- current_gun keeps meaning the usable gun: the selected slot, else the
-- first one holding a gun.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

_G.defines = { inventory = { character_guns = 1, character_ammo = 2, character_armor = 3 } }
package.loaded["scripts.companion"] = {}
package.loaded["scripts.items"] = {}

local equipment = require("scripts.equipment")

local function character(guns, ammo, armor, selected)
  local inv = { guns, ammo or {}, armor or {} }
  return {
    valid = true,
    selected_gun_index = selected or 1,
    get_inventory = function(idx) return inv[idx] end,
  }
end

local function stack(name, count)
  return { valid_for_read = true, name = name, count = count or 1 }
end

-- the fix: a gun in a second slot is visible in the summary
do
  local c = character(
    { stack("pistol"), stack("submachine-gun") },
    { stack("firearm-magazine", 10) },
    { stack("light-armor") })
  local s = equipment.summary(c)
  check(s.gun == "pistol + submachine-gun",
    "summary lists every gun slot ('" .. tostring(s.gun) .. "')")
  check(s.ammo["firearm-magazine"] == 10, "ammo slot read")
  check(s.armor == "light-armor", "armor slot read")
end

-- one gun, empty second slot: the old single-name form
do
  local s = equipment.summary(character({ stack("pistol"), {} }, {}, {}))
  check(s.gun == "pistol", "a lone gun reads as before")
end

-- no guns at all: nil, not ""
do
  local s = equipment.summary(character({ {}, {} }, {}, {}))
  check(s.gun == nil, "no gun equipped reads as nil")
end

-- ammo aggregation across slots (same ammo in two slots)
do
  local s = equipment.summary(character({ stack("pistol") },
    { stack("firearm-magazine", 10), stack("firearm-magazine", 5) }, {}))
  check(s.ammo["firearm-magazine"] == 15, "ammo counts sum across slots")
end

-- current_gun: the selected slot, else the first with a gun
do
  local name, slot = equipment.current_gun(character({ stack("pistol"), stack("submachine-gun") }, {}, {}, 2))
  check(name == "submachine-gun" and slot == 2, "current_gun follows the selected slot")
  local name2, slot2 = equipment.current_gun(character({ stack("pistol"), stack("submachine-gun") }, {}, {}, 1))
  check(name2 == "pistol" and slot2 == 1, "current_gun with slot 1 selected")
  local name3 = equipment.current_gun(character({ {}, stack("submachine-gun") }, {}, {}, 1))
  check(name3 == "submachine-gun", "current_gun falls back to the first gun found")
end

os.exit(failures == 0 and 0 or 1)
