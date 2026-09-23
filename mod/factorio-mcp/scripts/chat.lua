local companion = require("scripts.companion")

local M = {}

local MAX_MESSAGES = 200

function M.on_console_chat(event)
  if not event.player_index then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  local chat = storage.chat
  chat.messages[#chat.messages + 1] = {
    id = chat.next_id,
    tick = event.tick,
    player = player.name,
    text = event.message,
  }
  chat.next_id = chat.next_id + 1
  if #chat.messages > MAX_MESSAGES then
    table.remove(chat.messages, 1)
  end
end

-- Everything since the cursor except this character's own lines (unless
-- include_self, e.g. for a full transcript). Without since_id the
-- character's stored cursor is used; every read advances it.
function M.get(params)
  local include_self = params.include_self == true
  local me = companion.context()
  storage.cursors = storage.cursors or {}
  local cur = storage.cursors[me]
  local since = tonumber(params.since_id) or (cur and cur.chat) or 0
  local out = {}
  for _, m in ipairs(storage.chat.messages) do
    if m.id > since and (include_self or not (m.bot and m.player == me)) then
      out[#out + 1] = m
    end
  end
  local last = storage.chat.next_id - 1
  if cur then cur.chat = math.max(cur.chat or 0, last) end
  return { messages = out, last_id = last }
end

-- Chat as the bound character: "[name] text", like a player speaking.
function M.say(params)
  if type(params.text) ~= "string" or params.text == "" then
    error("say requires text")
  end
  local name = companion.context()
  game.print("[color=#4EC9B0][" .. name .. "][/color] " .. params.text)
  M.log_bot_line(name, params.text)
  return {}
end

-- Agents hear each other: their lines go into the same chat log, tagged bot.
function M.log_bot_line(name, text)
  local chat = storage.chat
  chat.messages[#chat.messages + 1] = { id = chat.next_id, tick = game.tick, player = name, text = text, bot = true }
  chat.next_id = chat.next_id + 1
  if #chat.messages > MAX_MESSAGES then table.remove(chat.messages, 1) end
end

return M
