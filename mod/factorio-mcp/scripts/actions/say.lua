-- say as a job: speaks when the jobs queued before it have run (the instant
-- say tool speaks at once, which in a queued plan is before the work it
-- describes).
local chat = require("scripts.chat")

local M = {}

function M.start(task)
  if type(task.text) ~= "string" or task.text == "" then error("say requires text") end
  if #task.text > 400 then task.text = task.text:sub(1, 397) .. "..." end
end

function M.tick(task)
  chat.say({ text = task.text })
  return { status = "done", detail = "said: " .. task.text }
end

return M
