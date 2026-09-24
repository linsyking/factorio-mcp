-- Offline tests for scripts/combat.lua and the events.lua combat feed
-- (0.2.16): the alert panel read, the battlefield snapshot (damage layer,
-- dry turrets, enemy clusters, recent combat) and force-entity damage
-- aggregation / death events.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end
local function has(s, sub) return type(s) == "string" and string.find(s, sub, 1, true) ~= nil end

_G.storage = {}
_G.defines = {
  alert_type = { turret_out_of_ammo = 1, entity_under_attack = 2 },
  inventory = { turret_ammo = 1 },
}

local pf, ef = { name = "player" }, { name = "enemy" }
_G.game = {
  tick = 3776000,
  forces = { player = pf, enemy = ef },
  connected_players = {},
}

local c
package.preload["scripts.companion"] = function()
  return {
    require_companion = function() return c end,
    get = function() return c end,
    context = function() return "tester" end,
    name_of = function(e) return e.char_name end,
  }
end
package.preload["scripts.vision"] = function()
  return { filter_known = function(list) return list end }
end

local events = require("scripts.events")
local combat = require("scripts.combat")

-- world stubs ------------------------------------------------------------
local function ent(t)
  t.valid = true
  t.position = t.position or { x = 0, y = 0 }
  t.health = t.health or 100
  t.max_health = t.max_health or 100
  t.force = t.force or pf
  t.type = t.type or "wall"
  return t
end

local wallA = ent { name = "stone-wall", position = { x = 103, y = 85 }, health = 180, max_health = 350, un = 1 }
local turretC = ent { name = "gun-turret", type = "turret", position = { x = 101, y = 98 }, health = 90,
  max_health = 400, un = 2 }
local turretB = ent { name = "gun-turret", type = "turret", position = { x = 101, y = 91 }, un = 3 }
local turretE = ent { name = "gun-turret", type = "turret", position = { x = 102, y = 91 }, un = 4 }
local laserF = ent { name = "laser-turret", type = "turret", position = { x = 104, y = 91 }, un = 5 }
local chest = ent { name = "iron-chest", type = "container", position = { x = 6, y = -5 }, un = 6 }
local inserterD = ent { name = "inserter", type = "inserter", position = { x = 12, y = 7 }, health = 40,
  max_health = 150, un = 7 }
local nearWall1 = ent { name = "stone-wall", position = { x = 110, y = 95 }, un = 8 }
local nearWall2 = ent { name = "stone-wall", position = { x = 65, y = -40 }, un = 9 }

local inv_b = { is_empty = function() return true end }
local inv_e = { is_empty = function() return false end }
turretB.get_inventory = function() return inv_b end
turretE.get_inventory = function() return inv_e end
laserF.get_inventory = function() return nil end -- energy turret: no ammo inventory

local enemies = {}
for _, p in ipairs {
  { 127, 94 }, { 128, 96 }, { 129, 95 }, { 128, 94 }, { 129, 96 }, { 127, 95 },
} do
  enemies[#enemies + 1] = ent { name = "small-biter", type = "unit", position = { x = p[1], y = p[2] },
    force = ef, health = 5, max_health = 5 }
end
enemies[#enemies + 1] = ent { name = "biter-spawner", type = "unit-spawner", position = { x = 130, y = 90 },
  force = ef, health = 500, max_health = 500 }
for _, p in ipairs { { 60, -40 }, { 61, -40 }, { 60, -41 } } do
  enemies[#enemies + 1] = ent { name = "small-spitter", type = "unit", position = { x = p[1], y = p[2] },
    force = ef, health = 5, max_health = 5 }
end
enemies[#enemies + 1] = ent { name = "medium-biter", type = "unit", position = { x = 200, y = 200 },
  force = ef, health = 20, max_health = 20 }

local force_ents = { wallA, turretC, turretB, turretE, laserF, chest, inserterD, nearWall1, nearWall2 }
local turrets = { turretB, turretE, laserF }

local surface = {
  name = "nauvis", index = 1,
  find_entities_filtered = function(opts)
    if opts.force == ef then return enemies end
    if opts.type == "turret" then return turrets end
    if opts.position then
      local near, r = {}, opts.radius or 120
      for _, e in ipairs(force_ents) do
        local dx, dy = e.position.x - opts.position.x, e.position.y - opts.position.y
        if dx * dx + dy * dy <= r * r then near[#near + 1] = e end
      end
      return near
    end
    return force_ents
  end,
}
c = { force = pf, surface = surface, position = { x = 0, y = 0 } }

-- alerts -------------------------------------------------------------------
game.connected_players = {}
local a = combat.alerts({})
check(has(a.note, "no connected player"), "alerts: no connected player explains itself")

local panel = {
  [1] = {
    [1] = { -- turret_out_of_ammo
      { tick = 3775900, target = turretB },
      { tick = 3775700, position = { x = 50, y = 50 }, prototype = { name = "artillery-turret" } },
    },
    [2] = { -- entity_under_attack
      { tick = 3775800, position = { x = 105, y = 80 }, prototype = { name = "stone-wall" } },
    },
  },
}
game.connected_players = { { name = "linsyking", force = pf, get_alerts = function() return panel end } }
a = combat.alerts({})
check(#a.groups == 2 and a.groups[1].type == "turret_out_of_ammo", "alerts: alert types come from the enum")
check(a.groups[1].count == 2 and #a.groups[1].alerts == 2, "alerts: entries counted per type")
check(a.groups[2].type == "entity_under_attack" and a.groups[2].count == 1,
  "alerts: groups sort by count, biggest first")
local first, second = a.groups[1].alerts[1], a.groups[1].alerts[2]
check(first.name == "artillery-turret" and first.x == 50 and first.tick == 3775700,
  "alerts: prototype+position alerts render name and position")
check(second.name == "gun-turret" and second.x == 101 and second.y == 91,
  "alerts: target alerts take name and position from the entity")

-- battle_report --------------------------------------------------------------
local r = combat.report({})
local d = r.damaged
check(#d == 3, "battle_report: only entities below max health are damaged")
check(d[1].name == "gun-turret" and d[1].pct == 23, "battle_report: worst entity first (turret 90/400)")
check(d[2].name == "inserter" and d[2].pct == 27, "battle_report: second worst (inserter 40/150)")
check(d[3].name == "stone-wall" and d[3].pct == 51, "battle_report: third (wall 180/350)")
check(#r.turrets_no_ammo == 1 and r.turrets_no_ammo[1].name == "gun-turret"
  and r.turrets_no_ammo[1].x == 101, "battle_report: only the dry gun-turret is listed (energy turrets skipped)")

local cl = r.enemy_clusters
check(#cl == 3, "battle_report: enemies cluster by position (3 clusters)")
check(cl[1].count == 3 and cl[1].nearest.distance == 5 and cl[1].nearest.name == "stone-wall",
  "battle_report: clusters sort by distance to our nearest entity (5 tiles first)")
check(cl[2].count == 7 and cl[2].nearest.distance >= 15,
  "battle_report: the 7-entity nest cluster with its distance")
check(cl[3].nearest == nil, "battle_report: a cluster with nothing of ours nearby has no nearest")
check(has(table.concat(cl[2].top_names, ","), "small-biter") and cl[2].top_names[1] == "6x small-biter",
  "battle_report: cluster members named, biggest first")

-- events: force-entity damage aggregation ------------------------------------
events.on_entity_damaged({ entity = wallA })
events.on_entity_damaged({ entity = turretC })
local fed = 0
for _, e in ipairs(storage.events.list) do
  if e.kind == "under_attack" then fed = fed + 1 end
end
check(fed == 0, "events: damage inside the window does not push yet")
game.tick = game.tick + 300
events.flush_combat()
fed = 0
local last = nil
for _, e in ipairs(storage.events.list) do
  if e.kind == "under_attack" then fed, last = fed + 1, e end
end
check(fed == 1, "events: the window flushes as ONE under_attack event")
check(has(last.text, "gun-turret at (101.0, 98.0) 90/400"), "events: worst entity named first")
check(has(last.text, "stone-wall at (103.0, 85.0) 180/350"), "events: all damaged entities listed")
check(has(last.text, "2 of our entities"), "events: the event counts our damaged entities")

-- events: a death pushes immediately, with the cause -------------------------
events.on_entity_died({ entity = turretC, cause = ent { name = "behemoth-biter", type = "unit", force = ef } })
local died = nil
for _, e in ipairs(storage.events.list) do
  if e.kind == "destroyed" then died = e end
end
check(died ~= nil and has(died.text, "our gun-turret at (101.0, 98.0) was destroyed by behemoth-biter"),
  "events: force-entity deaths push immediately with the cause")

-- events: characters keep the personal throttled feed -------------------------
local me = ent { name = "character", char_name = "tester", type = "character", health = 200, max_health = 250 }
events.on_entity_damaged({ entity = me })
events.on_entity_damaged({ entity = me })
local attacked = 0
for _, e in ipairs(storage.events.list) do
  if e.kind == "attacked" then attacked = attacked + 1 end
end
check(attacked == 1, "events: character damage stays throttled to one event per window")
local personal = nil
for _, e in ipairs(storage.events.list) do
  if e.kind == "attacked" then personal = e end
end
check(personal ~= nil and personal.companion == "tester" and has(personal.text, "tester is being attacked"),
  "events: the personal attack event is companion-scoped")

-- events: enemy-force damage is ignored ----------------------------------------
local before = #storage.events.list
events.on_entity_damaged({ entity = enemies[1] })
check(#storage.events.list == before, "events: damage to enemy entities pushes nothing")

-- events.recent filters kinds and ticks ----------------------------------------
game.tick = game.tick + 100
local rec = events.recent(60 * 60)
local kinds = {}
for _, e in ipairs(rec) do kinds[e.kind] = true end
check(kinds.under_attack and kinds.destroyed and kinds.attacked, "events: recent keeps the combat kinds")
local noncombat = false
for _, e in ipairs(rec) do
  if not (e.kind == "under_attack" or e.kind == "destroyed" or e.kind == "attacked" or e.kind == "died") then
    noncombat = true
  end
end
check(not noncombat, "events: recent excludes non-combat events")
rec = events.recent(50) -- 50 ticks: everything pushed above is older than that now
check(#rec == 0, "events: recent respects the tick window")

os.exit(failures == 0 and 0 or 1)
