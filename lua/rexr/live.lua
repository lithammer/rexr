-- Keeps the reviewer current without the person pressing R: watches the
-- worktree, follows the agent's status, and hears new pull request reviews.
local M = {}

local watchers = {} ---@type table<string, uv.uv_fs_event_t>
local settle = assert(vim.uv.new_timer())
local jobs = {} ---@type vim.SystemObj[]

-- Children outlive Neovim unless told to stop.
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    for _, job in ipairs(jobs) do
      job:kill("sigterm")
    end
  end,
})

--- Call `on_change` once the worktree has been quiet for a moment after a
--- change under `root`. Watches the root and each directory holding a file
--- in `paths`, and their parents up to the root, so a file that appears in
--- a new directory is still seen: libuv can't watch a tree on Linux. Each
--- call replaces the last call's watches.
---@param paths string[] relative to root
function M.watch(root, paths, on_change)
  for _, w in pairs(watchers) do
    w:stop()
    w:close()
  end
  watchers = {}
  local dirs = { [root] = true }
  for _, p in ipairs(paths) do
    local d = vim.fs.dirname(root .. "/" .. p)
    while #d > #root and not dirs[d] do
      dirs[d] = true
      d = vim.fs.dirname(d)
    end
  end
  for d in pairs(dirs) do
    local w = vim.uv.new_fs_event()
    local ok = w
      and w:start(d, {}, function(err, name)
        -- Git's own files live under .git, which isn't watched; its entry
        -- in the root still stirs when they change.
        if not err and name ~= ".git" then
          settle:stop()
          settle:start(250, 0, vim.schedule_wrap(on_change))
        end
      end)
    if ok then
      watchers[d] = w
    elseif w then
      w:close()
    end
  end
end

--- Start `cmd` and call `on_line` with each line it prints, on the main loop.
local function stream(cmd, on_line, on_exit)
  local rest = ""
  local ok, job = pcall(vim.system, cmd, {
    text = true,
    stdout = function(_, data)
      if not data then
        return
      end
      local lines = vim.split(rest .. data, "\n", { plain = true })
      rest = table.remove(lines)
      for _, line in ipairs(lines) do
        vim.schedule(function()
          on_line(line)
        end)
      end
    end,
  }, on_exit and vim.schedule_wrap(on_exit) or nil)
  if ok then
    jobs[#jobs + 1] = job
  end
end

---@class rexr.AgentStatus
---@field state string working, idle, done, blocked, error, or exited
---@field kind? string what a blocked agent waits for: permission, question, auth

--- Call `on_status` with the agent's status as its pane reports it, now and
--- on every change.
---@param on_status fun(status: rexr.AgentStatus?)
function M.follow_agent(block, on_status)
  vim.system({ "rex", "block", "call", "-b", block, "program_status" }, { text = true }, function(r)
    local ok, data = pcall(vim.json.decode, r.stdout or "")
    local rec = ok and r.code == 0 and data.records and data.records[1]
    vim.schedule(function()
      on_status(rec and { state = rec.state, kind = rec.kind } or nil)
    end)
  end)
  -- The stream carries every pane in the session; decode only this one's.
  stream({ "rex", "events", "-s", block, "--json" }, function(line)
    if not line:find(block, 1, true) then
      return
    end
    local ok, ev = pcall(vim.json.decode, line)
    local e = ok and ev.payload and ev.payload.event
    if not (e and e.type == "block_event" and e.payload.block_id == block) then
      return
    end
    local name, p = e.payload.name, e.payload.payload
    if name == "program_status_changed" then
      on_status({ state = p.record.state, kind = p.record.kind })
    elseif name == "program_status_removed" then
      on_status(nil)
    elseif name == "child_exited" then
      on_status({ state = "exited" })
    end
  end)
end

--- Call `on_event` when someone reviews or pushes to `pr`. GitHub's event
--- subscriptions are a preview that may be off for the account; then `gh`
--- exits at once and nothing is called.
---@param pr rexr.PR
function M.follow_pr(pr, on_event)
  stream({
    "gh", "event", "listen", "--follow",
    "--resource", pr.url,
    "--event", "com.github.pull_request.review.submitted.v1,com.github.pull_request.head.changed.v1",
  }, function(line)
    if line ~= "" then
      on_event()
    end
  end)
end

return M
