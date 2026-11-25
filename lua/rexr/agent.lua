-- The agent pane this reviewer sends to, set by `rexr open`.
local M = { block = vim.env.REXR_AGENT ~= "" and vim.env.REXR_AGENT or nil }

---@return string? stdout, string? err
local function rex(args, stdin)
  local ok, r = pcall(function()
    return vim.system(vim.list_extend({ "rex" }, args), { text = true, stdin = stdin }):wait()
  end)
  if not ok then
    return nil, "rex is not installed"
  end
  if r.code ~= 0 then
    return nil, vim.trim(r.stderr ~= "" and r.stderr or r.stdout)
  end
  return r.stdout
end

--- What the agent reports through Rex's program status: working, idle,
--- blocked, ... or "unknown" when the program reports nothing.
---@return string? state, string? err
function M.state()
  local out, err = rex({ "block", "call", "-b", M.block, "program_status" })
  if not out then
    return nil, err
  end
  local ok, data = pcall(vim.json.decode, out)
  local rec = ok and data.records and data.records[1]
  return rec and rec.state or "unknown"
end

--- Paste text into the agent's prompt without submitting it.
---@return boolean ok, string? err
function M.send(text)
  if not M.block then
    return false, "no agent pane (use rexr open)"
  end
  local state, err = M.state()
  if not state then
    return false, err
  end
  if state == "blocked" then
    return false, "agent is waiting on a prompt"
  end
  local event = { block_id = M.block, event = { type = "paste", payload = { text = text } } }
  local _, perr = rex({ "api", "call", "-s", M.block, "block.event", "-" }, vim.json.encode(event))
  if perr then
    return false, perr
  end
  return true
end

return M
