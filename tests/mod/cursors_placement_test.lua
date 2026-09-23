-- Offline tests for per-character chat/event cursors (chat.lua, events.lua)
-- and placement explanations (placement.lua). Run: lua tests/mod/cursors_placement_test.lua
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

local ctx = "scout-1"
package.loaded["scripts.companion"] = {
  context = function() return ctx end,
  name_of = function() return nil end,
}
_G.game = { tick = 10, get_player = function() return { name = "human" } end, print = function() end }
_G.storage = {
  chat = { messages = {}, next_id = 1 },
  events = { list = {}, next_id = 1 },
  cursors = { ["scout-1"] = { chat = 0, events = 0 }, ["builder-1"] = { chat = 0, events = 0 } },
}

local chat = require("scripts.chat")
local events = require("scripts.events")

-- ------------------------------------------------------------- cursors
do
  chat.on_console_chat({ player_index = 1, tick = 10, message = "hello" })
  events.push("job_done", "job #1 done", { companion = "scout-1" })
  events.push("research_finished", "Research completed: automation.")
  events.push("job_done", "job #2 done", { companion = "builder-1" })

  local r1 = chat.get({})
  check(#r1.messages == 1 and r1.messages[1].text == "hello", "chat: first read returns the new message")
  local r2 = chat.get({})
  check(#r2.messages == 0, "chat: a second read (new session, same character) doesn't repeat it")
  ctx = "builder-1"
  check(#chat.get({}).messages == 1, "chat: another character has its own cursor")

  ctx = "scout-1"
  local e1 = events.get({})
  check(#e1.events == 2, "events: own event + force-wide event, not the other character's")
  check(#events.get({}).events == 0, "events: cursor persists across reads")
  check(#events.get({ since_id = 0 }).events == 2, "events: explicit since_id re-reads the backlog")

  chat.say({ text = "on my way" })
  ctx = "builder-1"
  local heard = chat.get({})
  check(#heard.messages == 1 and heard.messages[1].bot == true, "chat: agents hear each other's say lines")
  ctx = "scout-1"
  check(#chat.get({}).messages == 0, "chat: an agent doesn't hear its own lines")
end

-- ------------------------------------------------------------ placement
do
  local drill = {
    type = "mining-drill",
    collision_box = { left_top = { x = -0.9, y = -0.9 }, right_bottom = { x = 0.9, y = 0.9 } },
    get_mining_drill_radius = function() return 0.99 end,
    resource_categories = { ["basic-solid"] = true },
  }
  _G.prototypes = { entity = { ["burner-mining-drill"] = drill } }
  local resources = {}
  local surface = {
    find_entities_filtered = function(f)
      if f.type == "resource" then return resources end
      return {}
    end,
    get_tile = function() return { collides_with = function() return false end } end,
  }
  local c = { surface = surface, position = { x = 50, y = 50 } }
  local placement = require("scripts.placement")
  local why = placement.explain(c, "burner-mining-drill", { x = 10, y = 10 }, 0)
  check(why:find("no resource this drill can mine", 1, true) ~= nil, "placement: drill off ore is explained: " .. why)
  resources = { { prototype = { resource_category = "basic-solid" } } }
  why = placement.explain(c, "burner-mining-drill", { x = 10, y = 10 }, 0)
  check(why:find("no resource", 1, true) == nil, "placement: drill on ore is not blamed on missing ore")
end

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
