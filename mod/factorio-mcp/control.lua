-- factorio-mcp game side. The MCP server calls the single remote interface
-- factorio_mcp.rpc(method, params_json) over RCON (see docs/PROTOCOL.md).
local state = require("scripts.state")
local rpc = require("scripts.rpc")
local chat = require("scripts.chat")
local companion = require("scripts.companion")
local tasks = require("scripts.tasks")
local perceive = require("scripts.perceive")
local inspect = require("scripts.inspect")
local analyze = require("scripts.analyze")
local research = require("scripts.research")
local walk = require("scripts.actions.walk")
local drive = require("scripts.actions.drive")
local equipment = require("scripts.equipment")
local spatial = require("scripts.spatial")
local blueprint = require("scripts.blueprint")
local trains = require("scripts.trains")
local events = require("scripts.events")
local vision = require("scripts.vision")
local stats = require("scripts.stats")

local PROTOCOL_VERSION = 5

rpc.register("ping", function()
  return {
    protocol_version = PROTOCOL_VERSION,
    mod_version = script.active_mods["factorio-mcp"],
    factorio_version = script.active_mods["base"],
    space_age = script.active_mods["space-age"] ~= nil,
    tick = game.tick,
    characters = companion.binding_summary(),
  }
end)

-- binding / body. heartbeat is a scoped no-op: every scoped call refreshes
-- the session lease, and the MCP server calls this while idle.
rpc.register("bind", companion.bind)
rpc.register("heartbeat", function() return { tick = game.tick } end)
rpc.register("unbind", companion.unbind)
rpc.register("respawn", companion.spawn)
rpc.register("retire", function()
  tasks.cancel({ all = true })
  storage.tasks.by_companion[companion.context()] = nil
  return companion.retire()
end)

-- chat / events
rpc.register("get_chat", chat.get)
rpc.register("say", chat.say)
rpc.register("get_events", events.get)

-- perception (instant)
rpc.register("get_state", perceive.get_state)
rpc.register("check_inventory", perceive.check_inventory)
rpc.register("inspect", inspect.inspect)
rpc.register("analyze_factory", analyze.analyze_factory)
rpc.register("scan_area", spatial.scan_area)
rpc.register("can_place", spatial.can_place)
rpc.register("find_buildable_area", spatial.find_buildable_area)
rpc.register("describe_prototype", spatial.describe_prototype)
rpc.register("production_stats", stats.production_stats)
rpc.register("list_trains", trains.list_trains)
rpc.register("import_blueprint", blueprint.import)
rpc.register("list_blueprints", blueprint.list)
rpc.register("read_blueprint", blueprint.read)
rpc.register("export_blueprint", blueprint.export)

-- instant actions
rpc.register("start_research", research.start_research)
rpc.register("equip", equipment.equip)
rpc.register("exit_vehicle", drive.exit)
rpc.register("set_train_schedule", trains.set_train_schedule)

-- jobs (multi-tick actions run by tasks.lua)
rpc.register("enqueue", tasks.enqueue)
rpc.register("get_task", tasks.get)
rpc.register("list_tasks", tasks.list)
rpc.register("cancel", tasks.cancel)
-- get_chunk and echo are registered inside rpc.lua itself.

remote.add_interface("factorio_mcp", {
  rpc = function(method, params_json)
    rpc.dispatch(method, params_json)
  end,
})

local function initialize()
  state.init()
  companion.normalize_all()
end

script.on_init(initialize)
script.on_configuration_changed(initialize)
script.on_event(defines.events.on_console_chat, chat.on_console_chat)
script.on_nth_tick(120, function()
  companion.update_map_tag()
end)
script.on_nth_tick(vision.UPDATE_TICKS, function()
  vision.update(companion.entities())
end)
script.on_event(defines.events.on_tick, tasks.on_tick)
script.on_event(defines.events.on_script_path_request_finished, walk.on_path_finished)
script.on_event(defines.events.on_entity_damaged, events.on_entity_damaged,
  { { filter = "type", type = "character" } })
script.on_event(defines.events.on_entity_died, events.on_entity_died,
  { { filter = "type", type = "character" } })
script.on_event(defines.events.on_research_finished, events.on_research_finished)
