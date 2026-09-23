-- Offline tests for scripts/follow.lua (/follow, /follow-cam, /unfollow).
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

_G.defines = { controllers = { character = 1, remote = 7 } }
_G.storage = {}
local bodies = { agent = { valid = true, unit_number = 10, position = { x = 5, y = 5 }, surface = { index = 1 } } }
package.loaded["scripts.companion"] = {
  names = function() local n = {} for k in pairs(bodies) do n[#n + 1] = k end table.sort(n) return n end,
  record = function(name) return bodies[name] ~= nil and {} or nil end,
  get = function(name) local b = bodies[name] return (b and b.valid) and b or nil end,
}

local printed = {}
local screen = {}
local player = {
  index = 1, valid = true, connected = true, controller_type = 1, centered_on = nil,
  print = function(msg) printed[#printed + 1] = msg end,
  gui = { screen = screen },
}
function player.set_controller(p) player.controller_type = p.type end
function player.exit_remote_view() player.controller_type = 1 end
-- generic GUI element stub: children by name, a list of cameras for checks
local cameras = {}
local function element(spec, parent)
  local el = { type = spec.type, name = spec.name, caption = spec.caption, style = {}, children = {} }
  function el.add(child)
    local c = element(child, el)
    el.children[#el.children + 1] = c
    if child.name then el[child.name] = c end
    if child.type == "camera" then cameras[#cameras + 1] = c end
    return c
  end
  function el.destroy()
    if parent == screen then screen[spec.name] = nil end
  end
  return el
end
function screen.add(spec)
  local frame = element(spec, screen)
  screen[spec.name] = frame
  return frame
end
local other = { index = 2, name = "friend", character = { valid = true, unit_number = 77, position = { x = 1, y = 1 }, surface = { index = 1 } } }
_G.game = {
  tick = 100,
  get_player = function(i) return i == 1 and player or nil end,
  connected_players = { player, other },
}

local follow = require("scripts.follow")

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

follow.start(player, "agent", "cam")
local frame = screen["factorio_mcp_follow_cam"]
check(frame and frame.cam.entity == new_body, "follow-cam: camera window follows the agent")
follow.stop(player)
check(screen["factorio_mcp_follow_cam"] == nil and storage.followers[1] == nil, "unfollow: closes the window")

bodies.other = { valid = true, unit_number = 12, position = { x = 0, y = 0 }, surface = { index = 1 } }
printed = {}
follow.start(player, nil, "remote")
check(printed[1] and printed[1]:find("Which agent") ~= nil, "follow: asks which agent when there are several")
follow.stop(player)

-- /follow-cams: one camera per agent and per other connected player
cameras = {}
follow.start(player, nil, "cams")
local frame2 = screen["factorio_mcp_follow_cams"]
check(frame2 ~= nil and #cameras == 3, "follow-cams: cameras for 2 agents + 1 other player (not yourself)")
local watched = {}
for _, c in ipairs(cameras) do watched[c.entity] = true end
check(watched[bodies.agent] and watched[bodies.other] and watched[other.character], "follow-cams: each camera follows its body")
cameras = {}
follow.on_check()
check(#cameras == 0, "follow-cams: nothing changed, so no rebuild")
bodies.third = { valid = true, unit_number = 13, position = { x = 2, y = 2 }, surface = { index = 1 } }
follow.on_check()
check(#cameras == 4, "follow-cams: a new agent gets a camera")
follow.start(player, nil, "cams")
check(screen["factorio_mcp_follow_cams"] == nil and storage.followers[1] == nil, "follow-cams: running it again closes it")

-- status line: the agent's own text + what its running job is doing
local status = require("scripts.status")
local ctx = "agent"
package.loaded["scripts.companion"].context = function() return ctx end
check(status.line("agent") == "idle", "status: idle with no jobs and no text")
status.set({ text = "building the coal outpost" })
storage.tasks = { by_companion = { agent = { active = { type = "mine", resource = "coal", count = 60, _mine = { ops = 12 } },
  queue = { {}, {} } } } }
check(status.line("agent") == "building the coal outpost — mining coal 12/60 (+2 queued)",
  "status: agent text + running job progress")
storage.tasks.by_companion.agent.active = { type = "build_plan", _index = 8, steps = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } }
storage.tasks.by_companion.agent.queue = {}
check(status.line("agent") == "building the coal outpost — building 7/10", "status: build_plan progress")
status.set({ text = string.rep("x", 300) })
check(#storage.statuses.agent.text == 120, "status: long text is cut to 120 characters")
check(status.set({ text = "  " }).cleared and storage.statuses.agent == nil, "status: blank text clears it")

cameras = {}
status.set({ text = "smelting iron" })
follow.start(player, nil, "cams")
local cams = screen["factorio_mcp_follow_cams"]
local found = false
for _, cell in ipairs(cams.grid.children) do
  if cell.status and cell.status.caption and cell.status.caption:find("smelting iron", 1, true) then found = true end
end
check(found, "follow-cams: the agent's status line is shown under its camera")
status.set({ text = "now mining" })
follow.on_check()
found = false
for _, cell in ipairs(cams.grid.children) do
  if cell.status and cell.status.caption and cell.status.caption:find("now mining", 1, true) then found = true end
end
check(found, "follow-cams: status captions refresh without a rebuild")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
