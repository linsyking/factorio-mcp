-- Spectating for humans: keep a player's view on agent characters.
--
--   /follow [name]      remote view that stays centred on the agent (Esc exits and stops following)
--   /follow-cam [name]  a camera window that follows one agent while you keep playing
--   /follow-cams        one camera window per agent and per other connected player
--                       (toggle; windows come and go as agents/players do)
--   /unfollow           stop all of them
--
-- Windows are dragged by their title bar. Title-bar buttons: - / + window size,
-- z- / z+ camera zoom, # re-tile, x close. /follow-cams windows are tiled to
-- fit the screen: 3 per row at 1920 px, and all of them shrink together when
-- there are more than fit, so none opens off-screen. Tiling runs when a
-- window comes or goes, on #, and when the resolution or UI scale changes;
-- drags and -/+ last until then.
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
local ZOOMS = { 0.2, 0.3, 0.45, 0.6, 0.8, 1.0, 1.4, 2.0 }
local DEFAULT_ZOOM = 4
local ASPECT = 0.625                        -- camera height / width (16:10)
local DEFAULT_W = 600                       -- 3 windows per row at 1920x1080, 2 rows high
local MIN_W, MAX_W = 240, 1600
local STEP = 1.25                           -- -/+ size factor
-- GUI units around the camera: frame padding, title bar, status line, gaps
local PAD_W, PAD_H, GAP = 24, 100, 6
local LEFT, TOP, BOTTOM = 10, 60, 10
local OLD_SIZES = { { 320, 200 }, { 480, 300 }, { 640, 400 }, { 800, 500 }, { 960, 600 }, { 1280, 800 } } -- 0.2.7-0.2.11

local function state()
  storage.followers = storage.followers or {}
  return storage.followers
end

-- Per player and window: {w, h = camera size in GUI units, zoom = index into ZOOMS}.
local function view(player, wname)
  storage.cam_views = storage.cam_views or {}
  local mine = storage.cam_views[player.index] or {}
  storage.cam_views[player.index] = mine
  local v = mine[wname] or { w = DEFAULT_W, h = math.floor(DEFAULT_W * ASPECT), zoom = DEFAULT_ZOOM }
  if not v.w then -- saved by an older version as an index into its size list
    local old = OLD_SIZES[v.size or 3] or OLD_SIZES[3]
    v.w, v.h, v.size = old[1], old[2], nil
  end
  mine[wname] = v
  return v
end

local function screen_size(player)
  local scale, res = 1, { width = 1920, height = 1080 }
  pcall(function()
    scale = player.display_scale or 1
    res = player.display_resolution or res
  end)
  return res.width / scale, res.height / scale, scale -- GUI units
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

-- Where the single /follow-cam window opens.
local function slot(player)
  local _, _, scale = screen_size(player)
  return { math.floor(LEFT * scale), math.floor(TOP * scale) }
end

local function apply_view(frame, v)
  if frame.cam then
    frame.cam.style.width, frame.cam.style.height = v.w, v.h
    frame.cam.zoom = ZOOMS[v.zoom]
  end
  if frame.status then frame.status.style.maximal_width = v.w end
end

-- Camera size and grid for n windows on this screen: the default size if the
-- grid fits, else the largest size (all equal) at which all n fit, but never
-- below MIN_W. Returns w, h, cols, rows_that_fit.
local function layout(player, n)
  local W, H = screen_size(player)
  local usable_w, usable_h = W - LEFT - GAP, H - TOP - BOTTOM
  local function fits(w, cols)
    local rows = math.ceil(n / cols)
    return cols * (w + PAD_W + GAP) <= usable_w + 1e-6 and rows * (math.floor(w * ASPECT) + PAD_H + GAP) <= usable_h + 1e-6
  end
  local cols0 = math.max(1, math.floor(usable_w / (DEFAULT_W + PAD_W + GAP)))
  if n <= 0 or fits(DEFAULT_W, math.min(cols0, math.max(n, 1))) then
    return DEFAULT_W, math.floor(DEFAULT_W * ASPECT), cols0, math.floor(usable_h / (math.floor(DEFAULT_W * ASPECT) + PAD_H + GAP))
  end
  local best_w, best_cols = 0, 1
  for cols = 1, n do
    local rows = math.ceil(n / cols)
    local w_by_width = usable_w / cols - PAD_W - GAP
    local w_by_height = (usable_h / rows - PAD_H - GAP) / ASPECT
    local w = math.floor(math.min(w_by_width, w_by_height, DEFAULT_W))
    if w > best_w then best_w, best_cols = w, cols end
  end
  local w = math.max(MIN_W, best_w)
  local cols = best_w >= MIN_W and best_cols or math.max(1, math.floor(usable_w / (MIN_W + PAD_W + GAP)))
  local rows_fit = math.max(1, math.floor(usable_h / (math.floor(w * ASPECT) + PAD_H + GAP)))
  return w, math.floor(w * ASPECT), cols, rows_fit
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
  if wname ~= SINGLE then add_button(bar, wname, "tile", "#", "Tile all camera windows to fit the screen") end
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

-- Lay the /follow-cams windows out in a grid that fits the screen (in the
-- order of `order`, a list of window names). Windows beyond what fits even at
-- the minimum size are stacked with an offset, still on screen.
local function tile(player, order)
  local screen = player.gui.screen
  local list = {}
  for _, wname in ipairs(order) do
    if screen[wname] then list[#list + 1] = wname end
  end
  local n = #list
  if n == 0 then return end
  local w, h, cols, rows_fit = layout(player, n)
  local W, H, scale = screen_size(player)
  local cell_w, cell_h = w + PAD_W + GAP, h + PAD_H + GAP
  local capacity = cols * rows_fit
  for i, wname in ipairs(list) do
    local frame = screen[wname]
    local v = view(player, wname)
    v.w, v.h = w, h
    apply_view(frame, v)
    local x, y
    if i <= capacity then
      local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
      x, y = LEFT + col * cell_w, TOP + row * cell_h
    else -- overflow: stack over the grid with an offset, clamped on screen
      local k = i - capacity
      x = math.min(LEFT + 30 * k, W - cell_w)
      y = math.min(TOP + 30 * k, H - cell_h)
    end
    frame.location = { math.floor(math.max(0, x) * scale), math.floor(math.max(0, y) * scale) }
  end
end

-- /follow-cams: make the set of windows match the targets; re-tile when it changes.
local function sync_cams(player, entry, force_tile)
  local screen = player.gui.screen
  local want, order, changed = {}, {}, force_tile == true
  entry.closed = entry.closed or {}
  entry.windows = entry.windows or {}
  for _, t in ipairs(targets(player)) do
    if not entry.closed[t.key] then
      local wname = WIN_PREFIX .. t.key
      want[wname] = true
      order[#order + 1] = wname
      local frame = screen[wname]
      if not frame then
        open_window(player, wname, t.title, t.entity, t.agent, slot(player))
        changed = true
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
      changed = true
    end
  end
  entry.order = order
  if changed then tile(player, order) end
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
      entry.cams, entry.windows, entry.closed, entry.order = nil, nil, nil, nil
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
    open_window(player, SINGLE, "Following " .. name, body, name, slot(player))
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
        tile(player, entry.order or {})
      end
      tidy(state(), player.index)
    end
    return
  end
  if action == "tile" then
    local entry = state()[player.index]
    if entry and entry.cams then tile(player, entry.order or {}) end
    return
  end
  local v = view(player, wname)
  if action == "smaller" then
    v.w = math.max(MIN_W, math.floor(v.w / STEP)) v.h = math.floor(v.w * ASPECT)
  elseif action == "larger" then
    v.w = math.min(MAX_W, math.floor(v.w * STEP)) v.h = math.floor(v.w * ASPECT)
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

-- The screen changed size: re-tile that player's /follow-cams windows.
function M.on_display_changed(event)
  local player = game.get_player(event.player_index)
  local entry = state()[event.player_index]
  if player and entry and entry.cams then tile(player, entry.order or {}) end
end

-- On mod updates: remove windows of earlier versions (0.2.5/0.2.6 names).
function M.migrate()
  for _, player in pairs(game.players) do
    for _, old_name in ipairs({ "factorio_mcp_follow_cams", "factorio_mcp_follow_cam" }) do
      local w = player.gui.screen[old_name]
      if w then w.destroy() end
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
