-- Spectating for humans: keep a player's view on an agent character.
--
--   /follow [name]      remote view that stays centred on the agent (Esc exits and stops following)
--   /follow-cam [name]  a camera window that follows the agent while you keep playing
--   /unfollow           stop both
--
-- The view is re-centred every CHECK_TICKS: after the agent respawns (a new
-- body), or when the view was panned away. This is a viewing aid for people
-- watching; agents never see or use it.
local companion = require("scripts.companion")

local M = {}

M.CHECK_TICKS = 10
local CAM_NAME = "factorio_mcp_follow_cam"

local function state()
  storage.followers = storage.followers or {}
  return storage.followers
end

-- The agent to follow: the name given, or the only agent there is.
local function pick(player, name)
  local names = companion.names()
  if name == nil or name == "" then
    if #names == 1 then return names[1] end
    player.print(#names == 0 and "No agent characters right now."
      or ("Which agent? /follow <name> — agents: " .. table.concat(names, ", ")))
    return nil
  end
  if not companion.record(name) then
    player.print("No agent called '" .. name .. "'. Agents: " .. (#names > 0 and table.concat(names, ", ") or "none"))
    return nil
  end
  return name
end

local function close_cam(player)
  local frame = player.gui.screen[CAM_NAME]
  if frame then frame.destroy() end
end

local function open_cam(player, name, body)
  close_cam(player)
  local frame = player.gui.screen.add({ type = "frame", name = CAM_NAME, caption = "Following " .. name, direction = "vertical" })
  frame.location = { 20, 80 }
  local cam = frame.add({ type = "camera", name = "cam", position = body.position, surface_index = body.surface.index, zoom = 0.6 })
  cam.style.width, cam.style.height = 480, 300
  cam.entity = body
  frame.add({ type = "label", caption = "/unfollow to close" })
end

local function follow_remote(player, body)
  player.set_controller({ type = defines.controllers.remote, surface = body.surface, position = body.position })
  player.centered_on = body
end

function M.start(player, name, mode)
  name = pick(player, name)
  if not name then return end
  local body = companion.get(name)
  local s = state()
  local entry = s[player.index] or {}
  entry[mode] = name
  s[player.index] = entry
  if not body then
    player.print(name .. " has no body right now (dead?) — the view will jump to it when it respawns.")
    return
  end
  if mode == "remote" then
    follow_remote(player, body)
    player.print("Following " .. name .. ". Esc (or /unfollow) stops.")
  else
    open_cam(player, name, body)
  end
end

function M.stop(player)
  local s = state()
  local entry = s[player.index]
  s[player.index] = nil
  close_cam(player)
  if entry and entry.remote and player.controller_type == defines.controllers.remote then
    pcall(function() player.exit_remote_view() end)
  end
  player.print("Stopped following.")
end

function M.on_check()
  local s = state()
  for index, entry in pairs(s) do
    local player = game.get_player(index)
    if not (player and player.valid and player.connected) then
      s[index] = nil
    else
      if entry.remote then
        local body = companion.get(entry.remote)
        if player.controller_type ~= defines.controllers.remote then
          -- the player left remote view (Esc): respect it
          if entry._entered then
            entry.remote = nil
            player.print("Stopped following (you left the remote view). /follow to resume.")
          elseif body then
            follow_remote(player, body)
          end
        elseif body then
          entry._entered = true
          local c = player.centered_on
          if not (c and c.valid and c == body) then
            pcall(function() player.centered_on = body end)
          end
        end
      end
      if entry.cam then
        local frame = player.gui.screen[CAM_NAME]
        local body = companion.get(entry.cam)
        if not frame then
          entry.cam = nil -- closed
        elseif body and frame.cam.entity ~= body then
          frame.cam.entity = body
        end
      end
      if not entry.remote and not entry.cam then s[index] = nil end
    end
  end
end

function M.register_commands()
  commands.add_command("follow", "Keep your view on an agent character: /follow [name] (Esc or /unfollow stops).",
    function(cmd)
      local p = cmd.player_index and game.get_player(cmd.player_index)
      if p then M.start(p, cmd.parameter, "remote") end
    end)
  commands.add_command("follow-cam", "Open a camera window that follows an agent: /follow-cam [name].",
    function(cmd)
      local p = cmd.player_index and game.get_player(cmd.player_index)
      if p then M.start(p, cmd.parameter, "cam") end
    end)
  commands.add_command("unfollow", "Stop following agents (/follow, /follow-cam).", function(cmd)
    local p = cmd.player_index and game.get_player(cmd.player_index)
    if p then M.stop(p) end
  end)
end

return M
