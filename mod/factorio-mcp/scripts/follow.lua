-- Spectating for humans: keep a player's view on agent characters.
--
--   /follow [name]      remote view that stays centred on the agent (Esc exits and stops following)
--   /follow-cam [name]  a camera window that follows one agent while you keep playing
--   /follow-cams        one camera window per agent and per other connected player
--                       (toggle; windows come and go as agents/players do)
--   /unfollow           stop all of them
--
-- Windows are dragged by their title bar. Title-bar buttons: - / + window size,
-- z- / z+ camera zoom, x close (each window remembers its size and zoom).
-- Agent windows show the status line (scripts/status.lua) under the camera.
-- Cameras are re-pointed every CHECK_TICKS after a respawn. This is a viewing
-- aid for people watching; agents never see or use it.
local companion = require("scripts.companion")
local status = require("scripts.status")

local M = {}

M.CHECK_TICKS = 10
local WIN_PREFIX = "factorio_mcp_cam_"   -- one window per watched character
local SINGLE = WIN_PREFIX .. "single"    -- the /follow-cam window
local BTN = "factorio_mcp_cam_btn"       -- all title-bar buttons; tags.action says which
local SIZES = { { 320, 200 }, { 480, 300 }, { 640, 400 }, { 800, 500 }, { 960, 600 }, { 1280, 800 } }
local ZOOMS = { 0.2, 0.3, 0.45, 0.6, 0.8, 1.0, 1.4, 2.0 }
local DEFAULT_SIZE, DEFAULT_ZOOM = 3, 4

local function state()
  storage.followers = storage.followers or {}
  return storage.followers
end

-- Per player and window: {size = index into SIZES, zoom = index into ZOOMS}.
local function view(player, wname)
  storage.cam_views = storage.cam_views or {}
  local mine = storage.cam_views[player.index] or {}
  storage.cam_views[player.index] = mine
  local v = mine[wname] or { size = DEFAULT_SIZE, zoom = DEFAULT_ZOOM }
  mine[wname] = v
  return v
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

-- Everyone worth watching: agent characters, then other connected players.
local function targets(player)
  local list = {}
  for _, name in ipairs(companion.names()) do
    local b = companion.get(name)
    if b then list[#list + 1] = { key = "a_" .. name, title = name .. " (agent)", entity = b, agent = name } end
  end
  for _, p in pairs(game.connected_players) do
    local ch = p.character
    if p.index ~= player.index and ch and ch.valid then
      list[#list + 1] = { key = "p_" .. p.name, title = p.name, entity = ch }
    end
  end
  return list
end

-- Where window number i opens: a grid that fits the player's screen.
local function slot(player, i)
  local scale, res = 1, { width = 1920, height = 1080 }
  pcall(function()
    scale = player.display_scale or 1
    res = player.display_resolution or res
  end)
  local size = SIZES[DEFAULT_SIZE]
  local w, h = (size[1] + 24) * scale, (size[2] + 90) * scale
  local cols = math.max(1, math.floor((res.width - 20) / w))
  local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
  return { math.floor(10 + col * w), math.floor(60 + row * h) }
end

local function apply_view(frame, v)
  local size = SIZES[v.size]
  if frame.cam then
    frame.cam.style.width, frame.cam.style.height = size[1], size[2]
    frame.cam.zoom = ZOOMS[v.zoom]
  end
  if frame.status then frame.status.style.maximal_width = size[1] end
end

local function add_button(bar, wname, action, caption, tooltip)
  local spec = { type = "button", name = BTN .. "_" .. action, caption = caption, tooltip = tooltip,
    tags = { window = wname, action = action }, style = "frame_action_button" }
  local ok = pcall(function() bar.add(spec) end)
  if not ok then
    spec.style = nil
    bar.add(spec)
  end
end

-- A draggable window: title bar with buttons, a camera, and a status line for agents.
local function open_window(player, wname, title, body, agent, location)
  local screen = player.gui.screen
  if screen[wname] then screen[wname].destroy() end
  local frame = screen.add({ type = "frame", name = wname, direction = "vertical" })
  frame.location = location
  local bar = frame.add({ type = "flow", name = "bar", direction = "horizontal" })
  bar.add({ type = "label", caption = title, style = "frame_title" })
  local drag = bar.add({ type = "empty-widget", style = "draggable_space_header" })
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  drag.drag_target = frame
  add_button(bar, wname, "smaller", "-", "Smaller window")
  add_button(bar, wname, "larger", "+", "Larger window")
  add_button(bar, wname, "zoom_out", "z-", "Zoom out")
  add_button(bar, wname, "zoom_in", "z+", "Zoom in")
  add_button(bar, wname, "close", "x", "Close")
  local cam = frame.add({ type = "camera", name = "cam", position = body.position,
    surface_index = body.surface.index, zoom = ZOOMS[DEFAULT_ZOOM] })
  cam.entity = body
  if agent then
    local st = frame.add({ type = "label", name = "status", caption = status.line(agent) })
    st.style.single_line = false
  end
  apply_view(frame, view(player, wname))
  return frame
end

local function close_windows(player, only_multi)
  local names = {}
  for _, child in pairs(player.gui.screen.children) do
    local n = child.name
    if n and n:sub(1, #WIN_PREFIX) == WIN_PREFIX and not (only_multi and n == SINGLE) then names[#names + 1] = n end
  end
  for _, n in ipairs(names) do player.gui.screen[n].destroy() end
end

-- /follow-cams: make the set of windows match the targets.
local function sync_cams(player, entry)
  local screen = player.gui.screen
  local want = {}
  entry.closed = entry.closed or {}
  entry.windows = entry.windows or {}
  local n = 0
  for _, t in ipairs(targets(player)) do
    if not entry.closed[t.key] then
      n = n + 1
      local wname = WIN_PREFIX .. t.key
      want[wname] = true
      local frame = screen[wname]
      if not frame then
        open_window(player, wname, t.title, t.entity, t.agent, slot(player, n))
      else
        if frame.cam and frame.cam.entity ~= t.entity then frame.cam.entity = t.entity end
        if t.agent and frame.status then frame.status.caption = status.line(t.agent) end
      end
      entry.windows[wname] = true
    end
  end
  for wname in pairs(entry.windows) do
    if not want[wname] then
      if screen[wname] then screen[wname].destroy() end
      entry.windows[wname] = nil
    end
  end
end

local function follow_remote(player, body)
  player.set_controller({ type = defines.controllers.remote, surface = body.surface, position = body.position })
  player.centered_on = body
end

local function tidy(s, index)
  local e = s[index]
  if e and not e.remote and not e.cam and not e.cams then s[index] = nil end
end

function M.start(player, name, mode)
  local s = state()
  local entry = s[player.index] or {}
  s[player.index] = entry
  if mode == "cams" then
    if entry.cams then
      close_windows(player, true)
      entry.cams, entry.windows, entry.closed = nil, nil, nil
    else
      entry.cams, entry.windows, entry.closed = true, {}, {}
      sync_cams(player, entry)
    end
    tidy(s, player.index)
    return
  end
  name = pick(player, name)
  if not name then tidy(s, player.index) return end
  local body = companion.get(name)
  entry[mode] = name
  if not body then
    player.print(name .. " has no body right now (dead?) — the view will jump to it when it respawns.")
    return
  end
  if mode == "remote" then
    follow_remote(player, body)
    player.print("Following " .. name .. ". Esc (or /unfollow) stops.")
  else
    open_window(player, SINGLE, "Following " .. name, body, name, slot(player, 1))
  end
end

function M.stop(player)
  local s = state()
  local entry = s[player.index]
  s[player.index] = nil
  close_windows(player, false)
  if entry and entry.remote and player.controller_type == defines.controllers.remote then
    pcall(function() player.exit_remote_view() end)
  end
  player.print("Stopped following.")
end

-- Title-bar buttons.
function M.on_gui_click(event)
  local el = event.element
  if not (el and el.valid and el.name and el.name:sub(1, #BTN) == BTN) then return end
  local player = game.get_player(event.player_index)
  local tags = el.tags or {}
  local wname, action = tags.window, tags.action
  if not (player and wname and action) then return end
  local frame = player.gui.screen[wname]
  if not frame then return end
  if action == "close" then
    frame.destroy()
    local entry = state()[player.index]
    if entry then
      if wname == SINGLE then
        entry.cam = nil
      elseif entry.windows then
        entry.windows[wname] = nil
        entry.closed = entry.closed or {}
        entry.closed[wname:sub(#WIN_PREFIX + 1)] = true -- stays closed until /follow-cams again
      end
      tidy(state(), player.index)
    end
    return
  end
  local v = view(player, wname)
  if action == "smaller" then v.size = math.max(1, v.size - 1)
  elseif action == "larger" then v.size = math.min(#SIZES, v.size + 1)
  elseif action == "zoom_out" then v.zoom = math.max(1, v.zoom - 1)
  elseif action == "zoom_in" then v.zoom = math.min(#ZOOMS, v.zoom + 1)
  end
  apply_view(frame, v)
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
        local frame = player.gui.screen[SINGLE]
        local body = companion.get(entry.cam)
        if not frame then
          entry.cam = nil -- closed
        else
          if body and frame.cam and frame.cam.entity ~= body then frame.cam.entity = body end
          if frame.status then frame.status.caption = status.line(entry.cam) end
        end
      end
      if entry.cams then sync_cams(player, entry) end
      tidy(s, index)
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
  commands.add_command("follow-cams", "Toggle one camera window per agent and per other player.",
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
