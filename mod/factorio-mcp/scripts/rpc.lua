-- Single RPC entry point for the MCP server (see docs/PROTOCOL.md).
-- Params arrive as a JSON string; the response is printed to the RCON
-- connection as a {ok, data|error} JSON envelope. Envelopes larger than
-- CHUNK_SIZE are stored in storage.rpc_outbox and streamed back part by part
-- via get_chunk.
--
-- Scoping: every method except the UNSCOPED ones acts as ONE character and
-- requires {companion = <name>, session = <token>} from a live binding (see
-- companion.bind). The binding check is a safety mechanism against two MCP
-- instances driving one character — not coordination policy.
local companion = require("scripts.companion")

local M = {}

M.handlers = {}

local CHUNK_SIZE = 3400
local OUTBOX_TTL_TICKS = 5 * 60 * 60 -- stored chunked responses expire after 5 minutes

local UNSCOPED = { ping = true, echo = true, get_chunk = true, bind = true }

-- "__factorio-mcp__/scripts/x.lua:12: message" -> "message"
function M.clean_error(err)
  local msg = tostring(err)
  return (msg:gsub("^__[%w%-_]+__/[%w%-_/%.]+:%d+: ", ""))
end

function M.register(name, fn)
  M.handlers[name] = fn
end

-- never_chunk: get_chunk replies must always arrive whole.
local function respond(tbl, never_chunk)
  local json = helpers.table_to_json(tbl)
  if never_chunk or #json <= CHUNK_SIZE then
    rcon.print(json)
    return
  end
  local parts = {}
  for i = 1, #json, CHUNK_SIZE do
    parts[#parts + 1] = string.sub(json, i, i + CHUNK_SIZE - 1)
  end
  local box = storage.rpc_outbox
  local id = box.next_id
  box.next_id = id + 1
  box.by_id[id] = { parts = parts, created_tick = game.tick }
  rcon.print(helpers.table_to_json({ ok = true, chunked = true, id = id, parts = #parts, data = parts[1] }))
end

local function prune_outbox()
  local box = storage.rpc_outbox
  for id, entry in pairs(box.by_id) do
    if game.tick - entry.created_tick > OUTBOX_TTL_TICKS then box.by_id[id] = nil end
  end
end

function M.dispatch(method, params_json)
  prune_outbox()
  local handler = M.handlers[method]
  if not handler then
    respond({ ok = false, error = "unknown method: " .. tostring(method) })
    return
  end
  local params = {}
  if params_json ~= nil and params_json ~= "" then
    local decoded = helpers.json_to_table(params_json)
    if type(decoded) ~= "table" then
      respond({ ok = false, error = "params must be a JSON object string" })
      return
    end
    params = decoded
  end
  local ok, result = pcall(function()
    if not UNSCOPED[method] then
      companion.touch(params.companion, params.session)
      companion.set_context(params.companion)
    end
    return handler(params)
  end)
  companion.set_context(nil)
  if ok then
    respond({ ok = true, data = result or {} }, method == "get_chunk")
  else
    respond({ ok = false, error = M.clean_error(result) })
  end
end

-- Built-in transport helpers; everything else registers from control.lua.

M.register("get_chunk", function(params)
  local id = tonumber(params.id)
  local entry = id and storage.rpc_outbox.by_id[id]
  if not entry then
    error("unknown chunk id " .. tostring(params.id)
      .. " — chunked responses expire after 5 minutes, re-run the original call")
  end
  local part = tonumber(params.part)
  local data = part and entry.parts[part]
  if not data then
    error("chunk " .. id .. " has " .. #entry.parts .. " parts; there is no part " .. tostring(params.part))
  end
  return { data = data }
end)

M.register("echo", function(params)
  local size = math.floor(math.min(tonumber(params.size) or 0, 200000))
  return { data = string.rep("x", math.max(size, 0)) }
end)

return M
