-- Spectating for humans: keep a player's view on an agent character.
--
--   /follow [name]      remote view that stays centred on the agent (Esc exits and stops following)
--   /follow-cam [name]  a camera window that follows the agent while you keep playing
--   /follow-cams        one window with a camera on every agent and every other connected player
--                       (toggle; it rebuilds itself as agents or players come, go or respawn)
--   /unfollow           stop all of them
--
-- The view is re-centred every CHECK_TICKS: after the agent respawns (a new
-- body), or when the view was panned away. This is a viewing aid for people
-- watching; agents never see or use it.
local companion = require("scripts.companion")
local status = require("scripts.status")

local M = {}

M.CHECK_TICKS = 10
local CAM_NAME = "factorio_mcp_follow_cam"
local CAMS_NAME = "factorio_mcp_follow_cams"

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
  local st = frame.add({ type = "label", name = "status", caption = status.line(name) })
  st.style.maximal_width = 480
  st.style.single_line = false
  frame.add({ type = "label", caption = "/unfollow to close" })
end

-- Everyone worth watching: agent characters, then other connected players.
local function targets(player)
  local list = {}
  for _, name in ipairs(companion.names()) do
    local b = companion.get(name)
    if b then list[#list + 1] = { label = name .. " (agent)", entity = b, agent = name } end
  end
  for _, p in pairs(game.connected_players) do
    local ch = p.character
    if p.index ~= player.index and ch and ch.valid then
      list[#list + 1] = { label = p.name, entity = ch }
    end
  end
  local sig = {}
  for i, t in ipairs(list) do sig[i] = t.label .. "#" .. tostring(t.entity.unit_number) end
  return list, table.concat(sig, "|")
end

local function close_cams(player)
  local frame = player.gui.screen[CAMS_NAME]
  if frame then frame.destroy() end
end

local function build_cams(player)
  local old = player.gui.screen[CAMS_NAME]
  local location = old and old.location
  if old then old.destroy() end
  local list, sig = targets(player)
  local frame = player.gui.screen.add({ type = "frame", name = CAMS_NAME, direction = "vertical",
    caption = "Agents and players — /follow-cams closes" })
  frame.location = location or { 20, 80 }
  if #list == 0 then
    frame.add({ type = "label", caption = "Nobody to watch right now; cameras appear as agents or players arrive." })
  end
  local cols = (#list <= 1) and 1 or ((#list <= 4) and 2 or 3)
  local grid = frame.add({ type = "table", name = "grid", column_count = cols })
  local agents = {}
  for i, t in ipairs(list) do
    local cell = grid.add({ type = "flow", name = "cell_" .. i, direction = "vertical" })
    cell.add({ type = "label", caption = t.label })
    local cam = cell.add({ type = "camera", position = t.entity.position,
      surface_index = t.entity.surface.index, zoom = 0.5 })
    cam.style.width, cam.style.height = 320, 200
    cam.entity = t.entity
    if t.agent then
      local st = cell.add({ type = "label", name = "status", caption = status.line(t.agent) })
      st.style.maximal_width = 320
      st.style.single_line = false
      agents[i] = t.agent
    end
  end
  return sig, agents
end

local function follow_remote(player, body)
  player.set_controller({ type = defines.controllers.remote, surface = body.surface, position = body.position })
  player.centered_on = body
end

function M.start(player, name, mode)
  if mode == "cams" then
    local s = state()
    local entry = s[player.index] or {}
    if player.gui.screen[CAMS_NAME] then
      close_cams(player)
      entry.cams = nil
    else
      entry.cams, entry.cam_agents = build_cams(player)
    end
    s[player.index] = (entry.remote or entry.cam or entry.cams) and entry or nil
    return
  end
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
  close_cams(player)
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
        else
          if body and frame.cam.entity ~= body then frame.cam.entity = body end
          if frame.status then frame.status.caption = status.line(entry.cam) end
        end
      end
      if entry.cams then
        if not player.gui.screen[CAMS_NAME] then
          entry.cams = nil -- closed
        else
          local _, sig = targets(player)
          if sig ~= entry.cams then
            entry.cams, entry.cam_agents = build_cams(player)
          else
            local grid = player.gui.screen[CAMS_NAME].grid
            for i, name in pairs(entry.cam_agents or {}) do
              local cell = grid and grid["cell_" .. i]
              if cell and cell.status then cell.status.caption = status.line(name) end
            end
          end
        end
      end
      if not entry.remote and not entry.cam and not entry.cams then s[index] = nil end
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
  commands.add_command("follow-cams", "Toggle a window with a camera on every agent and every other player.",
    function(cmd)
      local p = cmd.player_index and game.get_player(cmd.player_index)
      if p then M.start(p, nil, "cams") end
    end)
  commands.add_command("unfollow", "Stop following agents (/follow, /follow-cam, /follow-cams).", function(cmd)
    local p = cmd.player_index and game.get_player(cmd.player_index)
    if p then M.stop(p) end
  end)
end

return M
