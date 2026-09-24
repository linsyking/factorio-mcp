-- Item names with quality. Normal-quality items keep their plain name; any
-- other quality is written "name@quality" (e.g. "iron-plate@rare"). The same
-- syntax is accepted wherever a tool takes item names.
local M = {}

function M.key(name, quality)
  local q = quality
  if type(q) == "table" then q = q.name end
  if q == nil or q == "normal" then return name end
  return name .. "@" .. q
end

-- "iron-plate@rare" -> "iron-plate", "rare"; "iron-plate" -> "iron-plate", "normal"
function M.parse(key)
  local name, quality = string.match(key, "^(.-)@([%w%-_]+)$")
  if name and name ~= "" then return name, quality end
  return key, "normal"
end

-- LuaInventory.get_contents() in 2.x: array of {name, count, quality}.
function M.inventory_map(inv)
  local out = {}
  if not inv then return out end
  for _, it in ipairs(inv.get_contents()) do
    local k = M.key(it.name, it.quality)
    out[k] = (out[k] or 0) + it.count
  end
  return out
end

-- Item stack spec for insert/remove_item/get_item_count from a key.
function M.spec(key, count)
  local name, quality = M.parse(key)
  return { name = name, quality = quality, count = count }
end

function M.count(owner, key)
  local name, quality = M.parse(key)
  if quality == "normal" then return owner.get_item_count(name) end
  return owner.get_item_count({ name = name, quality = quality })
end

-- Give a stack to a character; what doesn't fit is dropped on the ground
-- next to it — never onto a belt (spill_item_stack's allow_belts defaults to
-- true, which put stray items on nearby belts), and left for pickup. Returns
-- how many were dropped.
function M.give(c, stack)
  local kept = c.insert(stack)
  local left = (stack.count or 0) - kept
  if left > 0 then
    local ok = pcall(c.surface.spill_item_stack, {
      position = c.position,
      stack = { name = stack.name, count = left, quality = stack.quality },
      force = c.force,
      enable_looted = true,
      allow_belts = false,
    })
    if not ok then return 0 end
  end
  return math.max(left, 0)
end

return M
