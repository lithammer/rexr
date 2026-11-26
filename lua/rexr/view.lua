local git = require("rexr.git")
local comments = require("rexr.comments")
local agent = require("rexr.agent")
local unified = require("rexr.unified")
local live = require("rexr.live")

local M = {
  ---@type rexr.File[]
  files = {},
  index = nil, ---@type integer?
  wins = {}, ---@type {files: integer, diff: integer}
  buf = nil, ---@type integer? the shown file's buffer
  hunks = nil, ---@type rexr.Hunk[]? nil for a removed file
  before = {}, ---@type string[] the shown file at the base
  -- Which comments the shown buffer carries: true for the side whose text
  -- it is, else a function from that side's lines to the buffer's.
  sides = {}, ---@type table<string, true|fun(line: integer): integer>
  rows = {}, ---@type table<integer, integer> file list line → index into files
  seq = 0, -- numbers comment buffers, which need a name for :w
}

local HELP = [[
rexr
  <CR>     open file (file list)
  ]f [f    next / previous file
  ]c [c    next / previous change
  ]d [d    next / previous comment
  c        comment on line or visual range
  x        delete draft under cursor
  K        show comments on this line
  s        send comments on this line to the agent (twice to resend)
  S        send all unsent drafts to the agent
  R        refresh files and GitHub threads
  q        quit]]

local function notify(msg, level)
  vim.notify("rexr: " .. msg, level)
end

local function winbar(text)
  return " " .. text:gsub("%%", "%%%%")
end

local function load(name)
  local buf = vim.fn.bufadd(name)
  vim.fn.bufload(buf)
  return buf
end

--- Highlight with treesitter when a parser for the filetype is installed;
--- otherwise the regex syntax stays.
local function highlight(buf)
  if vim.bo[buf].filetype ~= "" then
    pcall(vim.treesitter.start, buf)
  end
end

--- Where the cursor is, when it's in the diff window. New comments go on
--- the side whose text the buffer is.
local function here()
  if vim.api.nvim_get_current_win() ~= M.wins.diff or not M.index then
    return nil
  end
  local side = M.sides.RIGHT == true and "RIGHT" or "LEFT"
  return { side = side, path = M.files[M.index].path, buf = M.buf, lnum = vim.fn.line(".") }
end

---@class rexr.Row
---@field depth integer
---@field dir? string
---@field file? rexr.File

--- Lay files out as a tree: each directory heads its contents, directories
--- before files, and a chain of directories holding nothing else folds into
--- one header, as `pkg/cmd/version/`.
---@return rexr.Row[] rows, rexr.File[] files in row order
local function tree(files)
  local root = { dirs = {}, files = {} }
  for _, f in ipairs(files) do
    local node = root
    local parts = vim.split(f.path, "/", { plain = true })
    for i = 1, #parts - 1 do
      node.dirs[parts[i]] = node.dirs[parts[i]] or { dirs = {}, files = {} }
      node = node.dirs[parts[i]]
    end
    table.insert(node.files, f)
  end
  local function before(x, y)
    return x:lower() < y:lower()
  end
  local rows, order = {}, {}
  local function walk(node, depth)
    local names = vim.tbl_keys(node.dirs)
    table.sort(names, before)
    for _, name in ipairs(names) do
      local child, label = node.dirs[name], name
      while #child.files == 0 and vim.tbl_count(child.dirs) == 1 do
        local only = next(child.dirs)
        label, child = label .. "/" .. only, child.dirs[only]
      end
      rows[#rows + 1] = { depth = depth, dir = label .. "/" }
      walk(child, depth + 1)
    end
    table.sort(node.files, function(x, y)
      return before(x.path, y.path)
    end)
    for _, f in ipairs(node.files) do
      rows[#rows + 1] = { depth = depth, file = f }
      order[#order + 1] = f
    end
  end
  walk(root, 0)
  return rows, order
end

--- Take a new set of changed files, in the order the tree shows them, so
--- ]f and [f walk the list top to bottom.
local function set_files(files)
  local _, order = tree(files)
  M.files = order
  local paths = vim.tbl_map(function(f)
    return f.path
  end, order)
  live.watch(M.review.root, paths, function()
    M.refresh()
  end)
end

local STATUS_HL = { A = "Added", ["?"] = "Added", D = "Removed" }

function M.render_files()
  local r = M.review
  local lines = r.pr and { ("#%d %s"):format(r.pr.number, r.pr.title), "base " .. r.base:sub(1, 8), "" }
    or { "diff vs " .. r.base:sub(1, 8), "" }
  local marks = { { 0, 0, { line_hl_group = "Title" } } }
  local width = vim.api.nvim_win_get_width(M.wins.files)
  local index = {}
  for i, f in ipairs(M.files) do
    index[f] = i
  end
  M.rows = {}
  for _, row in ipairs((tree(M.files))) do
    local indent = string.rep("  ", row.depth)
    if row.dir then
      lines[#lines + 1] = indent .. row.dir
      marks[#marks + 1] = { #lines - 1, 0, { line_hl_group = "Directory" } }
    else
      local f = row.file
      local n = #comments.find(function(t)
        return t.path == f.path and not (t.sent or t.answered)
      end)
      local name = vim.fs.basename(f.path)
      local room = width - #indent - 2 - (n > 0 and 3 or 0)
      if #name > room then
        name = "…" .. name:sub(-(room - 1))
      end
      lines[#lines + 1] = indent .. f.status .. " " .. name
      M.rows[#lines] = index[f]
      marks[#marks + 1] = { #lines - 1, #indent, { end_col = #indent + 1, hl_group = STATUS_HL[f.status] or "Changed" } }
      if n > 0 then
        marks[#marks + 1] = { #lines - 1, 0, { virt_text = { { "●" .. n, "DiagnosticWarn" } }, virt_text_pos = "right_align" } }
      end
      if index[f] == M.index then
        marks[#marks + 1] = { #lines - 1, 0, { line_hl_group = "Visual" } }
      end
    end
  end
  if #M.files == 0 then
    lines[#lines + 1] = "(no changes)"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "? help"
  local buf = M.files_buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local ns = vim.api.nvim_create_namespace("rexr.files")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], m[3])
  end
end

function M.render_comments()
  if not M.index then
    return
  end
  comments.render(M.buf, M.files[M.index].path, M.sides)
end

--- Draw the diff over the shown buffer, sized to its window.
local function render_diff()
  if not M.index then
    return
  end
  if M.hunks then
    unified.render(M.wins.diff, M.hunks, M.before)
  else
    unified.render_removed(M.buf)
  end
end

-- The agent's status as its pane reports it, for the winbar.
local AGENT = {
  working = { "working", "DiagnosticWarn" },
  idle = { "idle", "DiagnosticOk" },
  done = { "done", "DiagnosticOk" },
  blocked = { "waiting on you", "DiagnosticError" },
  error = { "error", "DiagnosticError" },
  exited = { "exited", "DiagnosticError" },
}

--- The diff window's bar: the shown file on the left, the agent's status
--- on the right.
local function update_winbar()
  local f = M.index and M.files[M.index]
  if not f then
    return
  end
  local left = winbar(
    f.status == "D" and ("%s  removed"):format(f.path) or ("%s  %s → worktree"):format(f.path, M.review.base:sub(1, 8))
  )
  local right = ""
  if M.agent then
    -- An unknown state reads as idle, as Rex's program status asks.
    local label = AGENT[M.agent.state] or AGENT.idle
    local kind = M.agent.state == "blocked" and M.agent.kind and (" for " .. M.agent.kind) or ""
    right = ("%%#%s#● agent %s%s%%* "):format(label[2], label[1], kind)
  end
  vim.wo[M.wins.diff].winbar = left .. "%=" .. right
end

---@param status rexr.AgentStatus?
function M.set_agent(status)
  M.agent = status
  update_winbar()
end

local map -- set below; show() maps keys on each buffer it opens

--- Show file `i`, at its first change. With `view`, from winsaveview, it's
--- a refresh instead: keep the cursor where it was and leave the focus be,
--- which may be in a comment the person is writing.
function M.show(i, view)
  local f = M.files[i]
  if not f then
    return
  end
  M.index = i
  local base = M.review.base
  local old = load(("rexr://%s/%s"):format(base, f.old or f.path))
  -- An empty buffer still holds one empty line; an added file had none.
  local added = f.status == "A" or f.status == "?"
  M.before = added and {} or vim.api.nvim_buf_get_lines(old, 0, -1, false)
  if f.status == "D" then
    M.buf, M.hunks = old, nil
    M.sides = { LEFT = true }
  else
    M.buf = load(M.review.root .. "/" .. f.path)
    vim.bo[M.buf].buflisted = true
    -- Review, don't edit: `:set modifiable` to change the file anyway.
    vim.bo[M.buf].modifiable = false
    M.hunks = unified.hunks(M.before, vim.api.nvim_buf_get_lines(M.buf, 0, -1, false))
    local hunks = M.hunks
    M.sides = {
      RIGHT = true,
      LEFT = function(line)
        return unified.map_left(hunks, line)
      end,
    }
  end
  highlight(M.buf)

  local win = M.wins.diff
  vim.api.nvim_win_set_buf(win, M.buf)
  update_winbar()
  vim.wo[win].number = true
  -- Comment signs take the place of the line number; the space matters
  -- in a split beside the agent.
  vim.wo[win].signcolumn = "number"
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  render_diff()
  unified.fold(win, M.hunks)
  map(M.buf)

  M.render_comments()
  M.render_files()
  if view then
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview(view)
      vim.cmd("normal! zv")
    end)
    return
  end
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { M.hunks and unified.first(M.hunks) or 1, 0 })
  vim.cmd("normal! zz")
end

function M.step(delta)
  if #M.files > 0 then
    M.show((((M.index or 1) - 1 + delta) % #M.files) + 1)
  end
end

--- Ask for a comment in a float; `:w` saves it, `q` drops it.
local function input(title, cb)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  M.seq = M.seq + 1
  vim.api.nvim_buf_set_name(buf, "rexr-comment://" .. M.seq)
  local width = math.min(80, vim.o.columns - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = 8,
    row = math.floor((vim.o.lines - 10) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    title = " " .. title .. " ",
    footer = " :w save draft · q cancel ",
    footer_pos = "right",
  })
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
      vim.bo[buf].modified = false
      vim.schedule(close)
      if body ~= "" then
        cb(body)
      end
    end,
  })
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.cmd.startinsert()
end

function M.comment(l1, l2)
  local h = here()
  if not h then
    return
  end
  local s, e = math.min(l1, l2), math.max(l1, l2)
  input(("%s:%s"):format(h.path, s == e and s or (s .. "-" .. e)), function(body)
    comments.add({
      path = h.path,
      side = h.side,
      line = e,
      start_line = s ~= e and s or nil,
      code = vim.api.nvim_buf_get_lines(h.buf, s - 1, e, false),
      messages = { { author = "you", body = body } },
    })
  end)
end

local function send(threads)
  if #threads == 0 then
    return notify("nothing to send")
  end
  local text = comments.prompt(threads)
  local ok, err = agent.send(text)
  if ok then
    comments.mark_sent(threads)
    return notify(("sent %d; press Enter in the agent"):format(#threads))
  end
  local copied = pcall(vim.fn.setreg, "+", text)
  notify(err .. (copied and "; copied instead" or ""), vim.log.levels.WARN)
end

--- Open the threads on the cursor's line in a float; K again enters it.
function M.show_threads()
  local h = here()
  if not h then
    return
  end
  local threads = comments.at(h.path, M.sides, h.lnum)
  if #threads == 0 then
    return notify("no comments on this line")
  end
  local lines, ids = {}, {}
  for i, t in ipairs(threads) do
    if i > 1 then
      vim.list_extend(lines, { "", "---", "" })
    end
    vim.list_extend(lines, comments.markdown(t))
    ids[#ids + 1] = t.id
  end
  vim.lsp.util.open_floating_preview(lines, "markdown", {
    border = "rounded",
    title = " " .. table.concat(ids, " · ") .. " ",
    title_pos = "left",
    max_width = math.min(120, vim.api.nvim_win_get_width(M.wins.diff) - 4),
    max_height = math.floor(vim.o.lines * 0.6),
    focus_id = "rexr.threads",
  })
end

function M.send_here()
  local h = here()
  if not h then
    return
  end
  local all = comments.at(h.path, M.sides, h.lnum)
  local unsent = vim.tbl_filter(function(t)
    return not t.sent
  end, all)
  if #all == 0 or #unsent > 0 then
    return send(unsent)
  end
  -- Sent means pasted; the person may have cleared the prompt since. A
  -- second press on the same line soon after says they mean to resend.
  local key, now = h.path .. ":" .. h.lnum, vim.uv.now()
  if M.resend and M.resend.key == key and now - M.resend.at < 2000 then
    M.resend = nil
    return send(all)
  end
  M.resend = { key = key, at = now }
  notify("already sent; press s again to resend")
end

function M.send_all()
  send(comments.find(function(t)
    return t.kind == "draft" and not t.sent
  end))
end

function M.delete_here()
  local h = here()
  local drafts = h and vim.tbl_filter(function(t)
    return t.kind == "draft"
  end, comments.at(h.path, M.sides, h.lnum)) or {}
  if #drafts == 0 then
    return notify("no draft on this line")
  end
  comments.delete(drafts[#drafts].id)
end

--- Pick up what changed on disk: which files differ, and their text.
--- Keeps the shown file, its view and the focus.
function M.refresh()
  local current = M.index and M.files[M.index].path
  local view = M.index and vim.api.nvim_win_call(M.wins.diff, vim.fn.winsaveview) or {}
  vim.cmd("checktime")
  set_files(git.changed(M.review.base))
  local index
  for i, f in ipairs(M.files) do
    if f.path == current then
      index = i
    end
  end
  M.index = nil
  M.render_files()
  -- The shown file may no longer differ, as when the agent undid a change.
  M.show(index or 1, index and view or {})
end

M.on_refresh = function() end

map = function(buf)
  local function n(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, desc = desc })
  end
  n("]f", function() M.step(1) end, "next file")
  n("]c", function() unified.jump(M.hunks or {}, 1) end, "next change")
  n("[c", function() unified.jump(M.hunks or {}, -1) end, "previous change")
  n("[f", function() M.step(-1) end, "previous file")
  n("c", function() M.comment(vim.fn.line("."), vim.fn.line(".")) end, "comment")
  vim.keymap.set("x", "c", function()
    local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    M.comment(l1, l2)
  end, { buffer = buf, desc = "comment on range" })
  n("x", M.delete_here, "delete draft")
  n("K", M.show_threads, "show comments")
  n("s", M.send_here, "send comments on line")
  n("S", M.send_all, "send all drafts")
  n("R", function() M.refresh(); M.on_refresh() end, "refresh")
  n("q", "<Cmd>confirm qall<CR>", "quit")
  n("?", function() vim.notify(HELP) end, "help")
end

function M.open(review)
  M.review = review
  set_files(git.changed(review.base))

  M.files_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(M.files_buf, "rexr://files")
  vim.bo[M.files_buf].filetype = "rexr"
  M.wins.files = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.wins.files, M.files_buf)
  vim.cmd("rightbelow vsplit")
  M.wins.diff = vim.api.nvim_get_current_win()
  local fw = M.wins.files
  local longest = 0
  for _, row in ipairs((tree(M.files))) do
    longest = math.max(longest, 2 * row.depth + (row.dir and #row.dir or #vim.fs.basename(row.file.path) + 2))
  end
  vim.api.nvim_win_set_width(fw, math.min(32, math.max(20, longest + 4)))
  vim.wo[fw].winfixwidth = true
  vim.wo[fw].number = false
  vim.wo[fw].signcolumn = "no"
  vim.wo[fw].wrap = false
  vim.wo[fw].cursorline = true
  -- Removed lines are padded to the window's width.
  vim.api.nvim_create_autocmd("WinResized", { callback = render_diff })

  map(M.files_buf)
  vim.keymap.set("n", "<CR>", function()
    local i = M.rows[vim.fn.line(".")]
    if i then
      M.show(i)
    end
  end, { buffer = M.files_buf, desc = "open file" })

  comments.on_change = function()
    M.render_files()
    M.render_comments()
  end
  M.render_files()
  M.show(1)
end

return M
