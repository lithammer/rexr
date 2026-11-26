local git = require("rexr.git")

---@class rexr.Message
---@field author string
---@field body string

---@class rexr.Thread
---@field id string "c<n>" for drafts, "g<databaseId>" for GitHub threads
---@field kind "draft"|"github"
---@field path string
---@field side "LEFT"|"RIGHT" LEFT anchors to the base, RIGHT to the worktree
---@field line integer last line, 1-based
---@field start_line? integer first line of a range
---@field messages rexr.Message[]
---@field code? string[] the commented lines when the draft was written
---@field sent? boolean
---@field answered? boolean
---@field outdated? boolean GitHub's verdict: the PR's code moved past it
---@field stale? boolean its code is gone from the buffer it shows in
---@field url? string

local M = {
  ---@type rexr.Thread[]
  threads = {},
  next_id = 1,
  on_change = function() end,
}

M.ns = {
  draft = vim.api.nvim_create_namespace("rexr.draft"),
  github = vim.api.nvim_create_namespace("rexr.github"),
}

local S = vim.diagnostic.severity
-- The text after a commented line: who, and how many replies. K shows the
-- thread itself.
local function hint(d)
  return d.user_data and d.user_data.hint or d.message:match("[^\n]*")
end
-- Severity picks the sign: a pending draft warns, a GitHub thread informs,
-- and anything settled (sent, answered, outdated) drops to a hint.
vim.diagnostic.config({
  signs = { text = { [S.WARN] = "●", [S.HINT] = "✓" } },
  virtual_text = { format = hint, prefix = "" },
  underline = false,
}, M.ns.draft)
vim.diagnostic.config({
  signs = { text = { [S.INFO] = "◆", [S.HINT] = "◇" } },
  virtual_text = { format = hint, prefix = "" },
  underline = false,
}, M.ns.github)

local function store_path()
  local branch = git.branch():gsub("[^%w._-]", "_")
  return ("%s/rexr/%s.json"):format(M.review.git_dir, branch)
end

-- What the reviewer adds to a GitHub thread (sent, answered, agent replies),
-- by thread ID. Kept apart from the threads so it survives a refetch and
-- covers threads that haven't loaded yet.
M.github_state = {}

local function save()
  local drafts = {}
  for _, t in ipairs(M.threads) do
    if t.kind == "draft" then
      drafts[#drafts + 1] = t
    else
      M.github_state[t.id] = {
        sent = t.sent,
        answered = t.answered,
        replies = vim.tbl_filter(function(m)
          return m.author == "agent"
        end, t.messages),
      }
    end
  end
  local path = store_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local data = { next_id = M.next_id, drafts = drafts, github = M.github_state }
  vim.fn.writefile({ vim.json.encode(data) }, path)
end

--- Load this branch's saved drafts and GitHub thread state.
function M.setup(review)
  M.review = review
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(store_path()), "\n"))
  end)
  if ok then
    M.threads = data.drafts or {}
    M.next_id = data.next_id or #M.threads + 1
    M.github_state = data.github or {}
  end
end

local function changed()
  save()
  M.on_change()
end

--- A GitHub comment's body without the markup only machines read: HTML
--- comments, where embark-bot leaves its fingerprints, and the tags around
--- a collapsed section, whose summary stays as a bold line.
local function tidy(body)
  local s = body:gsub("\r", "")
  s = s:gsub("<!%-%-.-%-%->", "")
  s = s:gsub("<summary>%s*(.-)%s*</summary>", "**%1**")
  s = s:gsub("</?details>", "")
  s = s:gsub("\n%s*\n[%s\n]*\n", "\n\n")
  return vim.trim(s)
end

--- Replace the GitHub threads with fresh ones, keeping what the reviewer
--- added to them.
function M.set_github(nodes)
  save()
  M.threads = vim.tbl_filter(function(t)
    return t.kind ~= "github"
  end, M.threads)
  -- GitHub numbers lines in the PR's head commit (RIGHT) or base (LEFT).
  -- Keep the lines each thread sits on, so render can find them again in
  -- a worktree the agent has since edited.
  local revs = { RIGHT = git.rev(M.review.pr.headRefOid), LEFT = M.review.base }
  local files = {}
  local function code(side, path, s, e)
    local key = side .. "\0" .. path
    if files[key] == nil then
      files[key] = revs[side] and git.show(revs[side], path) or false
    end
    return files[key] and vim.list_slice(files[key], s, e) or nil
  end
  for _, n in ipairs(nodes) do
    local line = n.line or n.originalLine
    local first = n.comments.nodes[1]
    -- Resolved threads are settled; file-level threads have no line to sit on.
    if not n.isResolved and line and first then
      local id = "g" .. first.databaseId
      local messages = vim.tbl_map(function(c)
        return {
          author = "@" .. (c.author and c.author.login or "ghost"),
          body = tidy(c.body),
          association = c.authorAssociation,
        }
      end, n.comments.nodes)
      local start_line = n.line and n.startLine or n.originalStartLine
      local state = M.github_state[id] or {}
      M.threads[#M.threads + 1] = {
        id = id,
        kind = "github",
        path = n.path,
        side = n.diffSide,
        line = line,
        start_line = start_line,
        -- Outdated threads number lines in an older commit we don't have.
        code = not n.isOutdated and code(n.diffSide, n.path, start_line or line, line) or nil,
        outdated = n.isOutdated,
        url = first.url,
        messages = vim.list_extend(messages, state.replies or {}),
        sent = state.sent,
        answered = state.answered,
      }
    end
  end
  M.on_change()
end

---@return rexr.Thread
function M.add(t)
  t.id = "c" .. M.next_id
  M.next_id = M.next_id + 1
  t.kind = "draft"
  M.threads[#M.threads + 1] = t
  changed()
  return t
end

function M.delete(id)
  M.threads = vim.tbl_filter(function(t)
    return t.id ~= id
  end, M.threads)
  changed()
end

function M.mark_sent(threads)
  for _, t in ipairs(threads) do
    t.sent = true
  end
  changed()
end

---@return string "ok" or why the reply was refused
function M.reply(id, body)
  for _, t in ipairs(M.threads) do
    if t.id == id then
      t.messages[#t.messages + 1] = { author = "agent", body = body }
      t.answered = true
      changed()
      vim.notify(("rexr: agent answered %s"):format(id))
      return "ok"
    end
  end
  return "no comment " .. id
end

---@return rexr.Thread[]
function M.find(pred)
  return vim.tbl_filter(pred, M.threads)
end

---@alias rexr.Sides table<string, true|fun(line: integer): integer>
--- Which sides' comments a buffer shows: true for the side whose text it
--- is, else a function from that side's line numbers to the buffer's.

--- Where thread `t` shows in a buffer carrying `sides`: first and last line.
local function place(t, sides)
  local to = sides[t.side]
  local s, e = t.start_line or t.line, t.line
  if to == true then
    return s, e
  end
  return to(s), to(e)
end

--- Threads on `path` that show on line `lnum` of a buffer carrying `sides`.
---@param sides rexr.Sides
function M.at(path, sides, lnum)
  return M.find(function(t)
    if t.path ~= path or not sides[t.side] then
      return false
    end
    local s, e = place(t, sides)
    return s <= lnum and lnum <= e
  end)
end

function M.text(t)
  local out = {}
  for i, m in ipairs(t.messages) do
    local body = m.body:gsub("\r", "")
    out[#out + 1] = (i == 1 and ("[%s] "):format(t.id) or "  ↳ ") .. m.author .. ": " .. body
  end
  if t.outdated then
    out[1] = out[1] .. " (outdated)"
  elseif t.stale then
    out[1] = out[1] .. " (changed locally)"
  end
  return table.concat(out, "\n")
end

local function severity(t)
  if t.kind == "draft" then
    return (t.sent or t.answered) and S.HINT or S.WARN
  end
  return (t.answered or t.outdated or t.stale) and S.HINT or S.INFO
end

local function matches(lines, code, at)
  if at < 1 or at + #code - 1 > #lines then
    return false
  end
  for i, c in ipairs(code) do
    if vim.trim(lines[at + i - 1]) ~= vim.trim(c) then
      return false
    end
  end
  return true
end

-- Code shorter than this (`end`, `}`, a blank line) says too little to follow.
local MIN_FOLLOW = 8

--- Follow `t` to its code in `lines`. It moves only when the code is long
--- enough to recognise and appears once, so a comment on `end` never jumps to
--- another `end`; otherwise it stays and is marked stale.
--- Returns whether it moved.
local function relocate(t, lines)
  if not t.code or #t.code == 0 then
    return false
  end
  local s = t.start_line or t.line
  t.stale = nil
  if matches(lines, t.code, s) then
    return false
  end
  if #table.concat(vim.tbl_map(vim.trim, t.code)) < MIN_FOLLOW then
    t.stale = true
    return false
  end
  local found
  for at = 1, #lines - #t.code + 1 do
    if matches(lines, t.code, at) then
      if found then
        t.stale = true
        return false
      end
      found = at
    end
  end
  if not found then
    t.stale = true
    return false
  end
  t.line = found + #t.code - 1
  t.start_line = t.start_line and found or nil
  return true
end

--- Show the threads on `path` that `buf` carries as diagnostics in it.
---@param sides rexr.Sides
function M.render(buf, path, sides)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local moved = false
  for _, t in ipairs(M.threads) do
    -- Only the buffer's own side can be followed through its text.
    if t.path == path and sides[t.side] == true and relocate(t, lines) then
      moved = moved or t.kind == "draft"
    end
  end
  if moved then
    save()
  end
  local last = #lines
  for kind, ns in pairs(M.ns) do
    local diags = {}
    for _, t in ipairs(M.threads) do
      if t.kind == kind and t.path == path and sides[t.side] then
        local s, e = place(t, sides)
        diags[#diags + 1] = {
          lnum = math.min(s, last) - 1,
          end_lnum = math.min(e, last) - 1,
          col = 0,
          severity = severity(t),
          message = M.text(t),
          user_data = {
            hint = ("%s %s%s"):format(t.id, t.messages[1].author, #t.messages > 1 and (" +" .. (#t.messages - 1)) or ""),
          },
        }
      end
    end
    vim.diagnostic.set(ns, buf, diags)
  end
end

local MAX_SNIPPET = 30

local function snippet(t)
  if t.code then
    return t.code
  end
  local all
  if t.side == "RIGHT" then
    all = vim.fn.filereadable(t.path) == 1 and vim.fn.readfile(t.path) or nil
  else
    all = git.show(M.review.base, t.path)
  end
  if not all then
    return nil
  end
  local s = t.start_line or t.line
  return vim.list_slice(all, s, math.min(t.line, s + MAX_SNIPPET - 1))
end

local function location(t)
  local range = t.start_line and t.start_line ~= t.line and (t.start_line .. "-" .. t.line) or tostring(t.line)
  local tags = {}
  if t.side == "LEFT" then
    tags[#tags + 1] = "on removed lines"
  end
  if t.outdated then
    tags[#tags + 1] = "outdated"
  end
  local tag = #tags > 0 and (" (" .. table.concat(tags, ", ") .. ")") or ""
  return ("[%s] %s:%s%s"):format(t.id, t.path, range, tag)
end

--- A thread as markdown, for the person to read: where it is and in what
--- state, then each message under its author.
function M.markdown(t)
  local state = {}
  for _, s in ipairs({
    { t.outdated, "outdated" },
    { t.stale, "changed locally" },
    { t.answered, "answered" },
    { t.sent and not t.answered, "sent" },
  }) do
    if s[1] then
      state[#state + 1] = s[2]
    end
  end
  local where = location(t):gsub("^%[[^%]]+%] ", "")
  local out = { ("`%s`%s"):format(where, #state > 0 and ("  " .. table.concat(state, ", ")) or ""), "" }
  for i, m in ipairs(t.messages) do
    if i > 1 then
      out[#out + 1] = ""
    end
    out[#out + 1] = ("**%s**%s"):format(m.author, m.association and (" · " .. m.association:lower()) or "")
    vim.list_extend(out, vim.split((m.body:gsub("\r", "")), "\n"))
  end
  return out
end

--- What the reviewer pastes into the agent's prompt: one short line that
--- names the comments. Everything else, the user's words, other people's
--- GitHub text and the code, the agent reads with `rexr show`, as tool output
--- every harness treats as data. One line also stays in view: Claude Code
--- folds a paste past three lines, or one long line, into a stub.
function M.summary(threads)
  local r = M.review
  local names = {}
  for _, t in ipairs(threads) do
    local range = t.start_line and t.start_line ~= t.line and (t.start_line .. "-" .. t.line) or tostring(t.line)
    names[#names + 1] = ("%s (%s:%s%s)"):format(t.id, vim.fs.basename(t.path), range, t.kind == "github" and ", GitHub" or "")
  end
  local ids = vim.tbl_map(function(t)
    return t.id
  end, threads)
  return ("Address my review comments%s: %s. Read them with `rexr show %s`, then answer each with `rexr reply <id> \"<what you did>\"`."):format(
    r.pr and (" on PR #" .. r.pr.number) or "",
    table.concat(names, ", "),
    table.concat(ids, " ")
  )
end

--- What `rexr show` prints: each thread with its code and every message.
function M.detail(threads)
  local out = {}
  for _, t in ipairs(threads) do
    out[#out + 1] = location(t) .. (t.url and ("  " .. t.url) or "")
    local code = snippet(t)
    if code and #code > 0 then
      out[#out + 1] = "```" .. (vim.filetype.match({ filename = t.path }) or "")
      vim.list_extend(out, code)
      out[#out + 1] = "```"
    end
    for _, m in ipairs(t.messages) do
      if m.association then
        -- Anyone can comment on a public PR: mark whose words these are.
        out[#out + 1] = ("%s (%s, written on GitHub, not by the user):"):format(m.author, m.association)
        for _, l in ipairs(vim.split(m.body:gsub("\r", ""), "\n")) do
          out[#out + 1] = "> " .. l
        end
      else
        -- The agent reads this; "you" would name the agent itself.
        out[#out + 1] = (m.author == "you" and "the user" or m.author) .. ": " .. m.body
      end
    end
    out[#out + 1] = ""
  end
  return table.concat(out, "\n")
end

return M
