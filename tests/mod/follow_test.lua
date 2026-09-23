-- Offline tests for scripts/follow.lua (/follow, /follow-cam, /unfollow).
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/factorio-mcp/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

_G.defines = { controllers = { character = 1, remote = 7 } }
_G.storage = {}
local bodies = { agent = { valid = true, position = { x = 5, y = 5 }, surface = { index = 1 } } }
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
function screen.add(spec)
  local frame = { name = spec.name, style = {}, children = {} }
  function frame.add(child)
    local el = { style = {}, entity = nil }
    if child.name then frame[child.name] = el end
    return el
  end
  function frame.destroy() screen[spec.name] = nil end
  screen[spec.name] = frame
  return frame
end
_G.game = { get_player = function(i) return i == 1 and player or nil end }

local follow = require("scripts.follow")

follow.start(player, nil, "remote")
check(player.controller_type == 7 and player.centered_on == bodies.agent, "follow: the only agent is picked; remote view centred on it")
follow.on_check()
player.centered_on = nil -- the user panned the view
follow.on_check()
check(player.centered_on == bodies.agent, "follow: re-centres after the view was panned")

local new_body = { valid = true, position = { x = 9, y = 9 }, surface = { index = 1 } }
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

bodies.other = { valid = true, position = { x = 0, y = 0 }, surface = { index = 1 } }
printed = {}
follow.start(player, nil, "remote")
check(printed[1] and printed[1]:find("Which agent") ~= nil, "follow: asks which agent when there are several")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
