local M = {}

-- Initializes/migrates the storage schema. Safe to call repeatedly.
-- All fields any module needs MUST be declared here (single owner of the schema).
function M.init()
  storage.chat = storage.chat or { messages = {}, next_id = 1 }

  -- Jobs ("tasks"): one lane (queue + active) per character.
  storage.tasks = storage.tasks or {}
  storage.tasks.next_id = storage.tasks.next_id or 1
  storage.tasks.records = storage.tasks.records or {}
  storage.tasks.by_companion = storage.tasks.by_companion or {}
  -- chain id -> failure tick: late enqueues of a failed plan cancel instantly
  storage.tasks.failed_chains = storage.tasks.failed_chains or {}

  -- Characters (name -> record) and MCP session bindings (name -> lease).
  storage.companions = storage.companions or {}
  storage.bindings = storage.bindings or {}

  -- pathfinder bookkeeping: request id -> {name, task_id, tick}, and answers
  -- by request id (see actions/walk.lua). Kept across mod updates: the engine
  -- still answers requests made before the update.
  storage.path_requests = storage.path_requests or {}
  storage.path_results = storage.path_results or {}
  -- chunked RPC responses: { next_id, by_id = { [id] = { parts = {...}, created_tick } } }
  storage.rpc_outbox = storage.rpc_outbox or { next_id = 1, by_id = {} }
  -- event log read with cursors (see scripts/events.lua)
  storage.events = storage.events or { list = {}, next_id = 1 }
  -- fog of war: explored chunks per force/surface (see scripts/vision.lua)
  storage.vision = storage.vision or { explored = {} }
  -- per-character read positions in the chat and event logs (survive MCP
  -- reconnects, so a new session continues where the character left off)
  storage.cursors = storage.cursors or {}
  -- per-character scan_area letters, stable across scans
  storage.scan_letters = storage.scan_letters or {}
end

return M
