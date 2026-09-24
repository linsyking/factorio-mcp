-- Offline tests for scripts/follow.lua (/follow, /follow-cam, /follow-cams, /unfollow)
-- and scripts/status.lua (status lines under the cameras).
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

_G.defines = { controllers = { character = 1, remote = 7 } }
_G.storage = {}
local bodies = { agent = { valid = true, unit_number = 10, position = { x = 5, y = 5 }, surface = { index = 1 } } }
local ctx = "agent"
package.loaded["scripts.companion"] = {
  names = function() local n = {} for k in pairs(bodies) do n[#n + 1] = k end table.sort(n) return n end,
  record = function(name) return bodies[name] ~= nil and {} or nil end,
  get = function(name) local b = bodies[name] return (b and b.valid) and b or nil end,
  context = function() return ctx end,
}

-- GUI stub: elements with children by name; `screen.children` lists open windows.
local function element(spec, parent)
  local el = { type = spec.type, name = spec.name, caption = spec.caption, tags = spec.tags, style = {}, children = {},
    valid = true }
  function el.add(child)
    local c = element(child, el)
    el.children[#el.children + 1] = c
    if child.name then el[child.name] = c end
    return c
  end
  function el.destroy()
    el.valid = false
    for i, c in ipairs(parent.children) do if c == el then table.remove(parent.children, i) break end end
    if spec.name then parent[spec.name] = nil end
  end
  return el
end
local screen = { children = {} }
function screen.add(spec)
  local c = element(spec, screen)
  screen.children[#screen.children + 1] = c
  screen[spec.name] = c
  return c
end
local function windows()
  local out = {}
  for _, c in ipairs(screen.children) do out[#out + 1] = c end
  return out
end

local printed = {}
local player = {
  index = 1, valid = true, connected = true, controller_type = 1, centered_on = nil,
  display_scale = 1, display_resolution = { width = 1920, height = 1080 },
  print = function(msg) printed[#printed + 1] = msg end,
  gui = { screen = screen },
}
function player.set_controller(p) player.controller_type = p.type end
function player.exit_remote_view() player.controller_type = 1 end
local other = { index = 2, name = "friend", character = { valid = true, unit_number = 77, position = { x = 1, y = 1 }, surface = { index = 1 } } }
_G.game = {
  tick = 100,
  get_player = function(i) return i == 1 and player or nil end,
  connected_players = { player, other },
}

local follow = require("scripts.follow")
local status = require("scripts.status")

-- /follow
follow.start(player, nil, "remote")
check(player.controller_type == 7 and player.centered_on == bodies.agent, "follow: the only agent is picked; remote view centred on it")
follow.on_check()
player.centered_on = nil -- the user panned the view
follow.on_check()
check(player.centered_on == bodies.agent, "follow: re-centres after the view was panned")
local new_body = { valid = true, unit_number = 11, position = { x = 9, y = 9 }, surface = { index = 1 } }
bodies.agent.valid = false
follow.on_check()
bodies.agent = new_body
follow.on_check()
check(player.centered_on == new_body, "follow: follows the new body after a respawn")
player.controller_type = 1 -- Esc
follow.on_check()
check(storage.followers[1] == nil, "follow: leaving remote view stops following")

-- /follow-cam
follow.start(player, "agent", "cam")
local single = screen["factorio_mcp_cam_single"]
check(single and single.cam.entity == new_body, "follow-cam: camera window follows the agent")
check(single.cam.style.width == 640 and single.cam.style.height == 400, "follow-cam: default camera size 640x400")
follow.stop(player)
check(#windows() == 0 and storage.followers[1] == nil, "unfollow: closes the window")

bodies.other = { valid = true, unit_number = 12, position = { x = 0, y = 0 }, surface = { index = 1 } }
printed = {}
follow.start(player, nil, "remote")
check(printed[1] and printed[1]:find("Which agent") ~= nil, "follow: asks which agent when there are several")
follow.stop(player)

-- /follow-cams: one window per agent and per other connected player
status.set({ text = "smelting iron" })
follow.start(player, nil, "cams")
local w = windows()
check(#w == 3, "follow-cams: 3 windows (2 agents + 1 other player, not yourself)")
local a = screen["factorio_mcp_cam_a_agent"]
check(a and a.cam.entity == new_body and screen["factorio_mcp_cam_p_friend"].cam.entity == other.character,
  "follow-cams: each window's camera follows its character")
check(a.status and a.status.caption:find("smelting iron", 1, true) ~= nil, "follow-cams: status line under the agent's camera")
check(screen["factorio_mcp_cam_p_friend"].status == nil, "follow-cams: no status line for human players")
check(a.location[1] ~= screen["factorio_mcp_cam_a_other"].location[1], "follow-cams: windows open side by side")

-- title-bar buttons
local function click(win, action)
  follow.on_gui_click({ player_index = 1, element = win.bar["factorio_mcp_cam_btn_" .. action] })
end
click(a, "larger")
check(a.cam.style.width == 800 and a.cam.style.height == 500, "buttons: + makes the window larger")
click(a, "smaller") click(a, "smaller")
check(a.cam.style.width == 480, "buttons: - makes it smaller")
local z = a.cam.zoom
click(a, "zoom_in")
check(a.cam.zoom > z, "buttons: z+ zooms in")
click(screen["factorio_mcp_cam_a_other"], "close")
follow.on_check()
check(#windows() == 2 and screen["factorio_mcp_cam_a_other"] == nil, "buttons: x closes one window and it stays closed")

status.set({ text = "now mining" })
follow.on_check()
check(a.status.caption:find("now mining", 1, true) ~= nil, "follow-cams: status captions refresh")
bodies.third = { valid = true, unit_number = 13, position = { x = 2, y = 2 }, surface = { index = 1 } }
follow.on_check()
check(screen["factorio_mcp_cam_a_third"] ~= nil, "follow-cams: a new agent gets its own window")
bodies.beta = { valid = true, unit_number = 14, position = { x = 3, y = 3 }, surface = { index = 1 } }
follow.on_check()
local spots, overlap = {}, false
for _, win in ipairs(windows()) do
  local k = win.location[1] .. "," .. win.location[2]
  if spots[k] then overlap = true end
  spots[k] = true
end
check(screen["factorio_mcp_cam_a_beta"] ~= nil and not overlap,
  "follow-cams: a new agent (even sorting first) opens in a free spot, not on top of another window")
follow.start(player, nil, "cams")
check(#windows() == 0 and storage.followers[1] == nil, "follow-cams: running it again closes all")
follow.start(player, nil, "cams")
check(screen["factorio_mcp_cam_a_agent"].cam.style.width == 480, "follow-cams: a reopened window keeps its size")
follow.stop(player)

-- status line
ctx = "agent"
status.set({ text = "" })
storage.tasks = nil
check(status.line("agent") == "idle", "status: idle with no jobs and no text")
status.set({ text = "building the coal outpost" })
storage.tasks = { by_companion = { agent = { active = { type = "mine", resource = "coal", count = 60, _mine = { ops = 12 } },
  queue = { {}, {} } } } }
check(status.line("agent") == "building the coal outpost — mining coal 12/60 (+2 queued)",
  "status: agent text + running job progress")
storage.tasks.by_companion.agent.active = { type = "build_plan", _index = 8, steps = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } }
storage.tasks.by_companion.agent.queue = {}
check(status.line("agent") == "building the coal outpost — building 7/10", "status: build_plan progress")
game.tick = 100 + 12 * 60
storage.tasks.by_companion.agent.active = { type = "walk_to", target = { x = 80, y = -20 },
  _walk = { phase = "waiting", request_tick = 100 } }
check(status.line("agent") == "building the coal outpost — walking to (80, -20), waiting for a path (12 s)",
  "status: shows how long the character has been waiting for a path")
status.set({ text = string.rep("x", 300) })
check(#storage.statuses.agent.text == 120, "status: long text is cut to 120 characters")
check(status.set({ text = "  " }).cleared and storage.statuses.agent == nil, "status: blank text clears it")
local destroyed = false
storage.status_labels = { agent = { valid = true, destroy = function() destroyed = true end } }
status.update_labels()
check(destroyed and storage.status_labels == nil, "status: no text above characters (old labels are removed)")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
