-- The review lives in a tab: the changed files in a location list, and the
-- diff drawn over the real file buffers. Vim opens the files (]l, :ll, <CR>
-- in the list); rexr draws on whichever changed file a window in the tab
-- shows, and takes it all down when the tab closes.
local git = require("rexr.git")
local comments = require("rexr.comments")
local agent = require("rexr.agent")
local unified = require("rexr.unified")
local live = require("rexr.live")

---@class rexr.Shown a buffer rexr has drawn on
---@field path string
---@field hunks? rexr.Hunk[] nil for a removed file
---@field before string[] the file at the base
---@field sides rexr.Sides
---@field placed table<integer, true> windows already moved to the first change
---@field folded table<integer, rexr.Hunk[]> the hunks each window was folded for

local M = {
  files = {}, ---@type rexr.File[]
  by_path = {}, ---@type table<string, rexr.File>
  shown = {}, ---@type table<integer, rexr.Shown>
  -- Each file's first change once drawn, where its list entry then points.
  first = {}, ---@type table<string, integer>
  seq = 0, -- numbers comment buffers, which need a name for :w
  on_refresh = function() end,
}

local group = vim.api.nvim_create_augroup("rexr.view", { clear = true })

local function notify(msg, level)
  vim.notify("rexr: " .. msg, level)
end

local update_list -- below; the list points at what draw() finds

local function in_tab(win)
  return M.tab ~= nil and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == M.tab
end

--- The changed file `buf` holds: the worktree file, or for a removed file
--- its rexr:// base buffer.
---@return rexr.File?
local function file_of(buf)
  if not M.review then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local rev, path = name:match("^rexr://([^/]+)/(.+)$")
  if rev then
    local f = M.by_path[path]
    return f and f.status == "D" and f or nil
  end
  local root = M.review.root .. "/"
  local f = name:sub(1, #root) == root and M.by_path[name:sub(#root + 1)]
  return f and f.status ~= "D" and f or nil
end

-- Buffer-local maps on the files rexr draws on. Navigation keeps Vim's own
-- keys; actions sit on <localleader>. The file's own maps on those keys,
-- such as the LSP's K, are kept aside and put back with the review's end.
local maps ---@type { [1]: string, [2]: string, [3]: string|function, [4]: string }[]
local saved = {} ---@type table<integer, table[]> buffer → its own maps rexr covered

local function map(buf)
  if not saved[buf] then
    saved[buf] = {}
    vim.api.nvim_buf_call(buf, function()
      for _, m in ipairs(maps) do
        local own = vim.fn.maparg(m[2], m[1], false, true)
        if own.buffer == 1 then
          table.insert(saved[buf], own)
        end
      end
    end)
  end
  for _, m in ipairs(maps) do
    vim.keymap.set(m[1], m[2], m[3], { buffer = buf, desc = m[4] })
  end
end

local function unmap(buf)
  for _, m in ipairs(maps) do
    pcall(vim.keymap.del, m[1], m[2], { buffer = buf })
  end
  for _, own in ipairs(saved[buf] or {}) do
    vim.api.nvim_buf_call(buf, function()
      vim.fn.mapset(own)
    end)
  end
  saved[buf] = nil
  -- An LSP that attached while rexr's K stood skipped its hover map, as it
  -- does for any K already there. Give it the one it would have set.
  local has_k = vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg("K", "n", false, true).buffer == 1
  end)
  if not has_k then
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
      if client:supports_method("textDocument/hover") then
        vim.keymap.set("n", "K", vim.lsp.buf.hover, { buffer = buf, desc = "vim.lsp.buf.hover()" })
        break
      end
    end
  end
end

--- Take rexr's drawing, comments and maps off `buf`.
local function clear(buf)
  M.shown[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) then
    unified.clear(buf)
    for _, ns in pairs(comments.ns) do
      vim.diagnostic.reset(ns, buf)
    end
    unmap(buf)
  end
end

--- Draw the diff and the comments over `buf`, sized to `win`.
local function draw(buf, win)
  local f = assert(file_of(buf))
  local added = f.status == "A" or f.status == "?"
  local s = M.shown[buf] or { placed = {}, folded = {} }
  s.path = f.path
  s.before = added and {} or (git.show(M.review.base, f.old or f.path) or {})
  if f.status == "D" then
    s.hunks, s.sides = nil, { LEFT = true }
    unified.render_removed(buf)
  else
    local hunks = unified.hunks(s.before, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    s.hunks = hunks
    s.sides = {
      RIGHT = true,
      LEFT = function(line)
        return unified.map_left(hunks, line)
      end,
    }
    unified.render(win, hunks, s.before)
  end
  M.shown[buf] = s
  local first = s.hunks and unified.first(s.hunks) or 1
  if M.first[f.path] ~= first then
    M.first[f.path] = first
    -- Not while :ll runs: changing its list then fails with E926.
    vim.schedule(update_list)
  end
  if vim.bo[buf].filetype ~= "" then
    pcall(vim.treesitter.start, buf)
  end
  comments.render(buf, f.path, s.sides)
  map(buf)
end

--- Fit a window in the tab to the file it shows: fold what's far from any
--- change, and on its first showing there, move to the first change.
local function frame(win, buf)
  local s = M.shown[buf]
  vim.wo[win].number = true
  -- Comment signs take the place of the line number; the space matters
  -- in a split beside the agent.
  vim.wo[win].signcolumn = "number"
  vim.wo[win].wrap = false
  -- Folding away what's far from any change is the review's own; a config
  -- that keeps folds open elsewhere still gets them here.
  vim.wo[win].foldenable = true
  vim.wo[win].foldlevel = 0
  if s.folded[win] ~= s.hunks or not s.hunks then
    s.folded[win] = s.hunks
    unified.fold(win, s.hunks)
  end
  -- Until draw() has found a file's first change, its list entry opens it
  -- at line 1, and :ll moves the cursor there after this runs. Follow up.
  if not s.placed[win] then
    s.placed[win] = true
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf and vim.fn.line(".", win) == 1 then
        vim.api.nvim_win_set_cursor(win, { M.first[s.path] or 1, 0 })
        vim.api.nvim_win_call(win, function()
          vim.cmd("normal! zvzz")
        end)
      end
    end)
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

--- The review window's bar: the shown file on the left, the agent's status
--- on the right.
local function update_winbar()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    return
  end
  local f = file_of(vim.api.nvim_win_get_buf(M.win))
  local left = ""
  if f then
    left = " " .. (f.status == "D" and ("%s  removed"):format(f.path) or ("%s  %s → worktree"):format(f.path, M.review.base:sub(1, 8)))
    left = left:gsub("%%", "%%%%")
  end
  local right = ""
  if M.agent then
    -- An unknown state reads as idle, as Rex's program status asks.
    local label = AGENT[M.agent.state] or AGENT.idle
    local kind = M.agent.state == "blocked" and M.agent.kind and (" for " .. M.agent.kind) or ""
    right = ("%%#%s#● agent %s%s%%* "):format(label[2], label[1], kind)
  end
  vim.wo[M.win].winbar = left .. "%=" .. right
end

---@param status rexr.AgentStatus?
function M.set_agent(status)
  M.agent = status
  update_winbar()
end

local STATUS = { A = "added", ["?"] = "new", D = "removed", R = "renamed", C = "copied", T = "type changed" }

--- How the files list shows its entries: status, name, directory, and how
--- many comments wait to be sent.
local function files_text(info)
  local items = vim.fn.getloclist(info.winid, { id = info.id, items = 1 }).items
  local rows, width = {}, 0
  for i = info.start_idx, info.end_idx do
    local path = items[i].user_data
    local f = M.by_path[path] or { status = " ", path = tostring(path) }
    local name = vim.fs.basename(f.path)
    width = math.max(width, vim.fn.strdisplaywidth(name))
    rows[#rows + 1] = { f, name }
  end
  local out = {}
  for _, r in ipairs(rows) do
    local f, name = r[1], r[2]
    local waiting = #comments.find(function(t)
      return t.path == f.path and not t.sent
    end)
    local dir = vim.fs.dirname(f.path)
    out[#out + 1] = ("%s %s%s  %s%s"):format(
      f.status,
      name,
      string.rep(" ", width - vim.fn.strdisplaywidth(name)),
      dir == "." and "" or dir .. "/",
      waiting > 0 and ("  ●" .. waiting) or ""
    )
  end
  return out
end

local function title()
  local r = M.review
  local base = "base " .. r.base:sub(1, 8)
  return r.pr and ("rexr #%d %s · %s"):format(r.pr.number, r.pr.title, base) or ("rexr diff · " .. base)
end

--- Put the changed files in the review window's location list, updating
--- the list in place so its selection stays, even under :lolder.
function update_list()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    return
  end
  local items = {}
  for _, f in ipairs(M.files) do
    local item = { lnum = M.first[f.path] or 1, user_data = f.path, text = STATUS[f.status] or "" }
    if f.status == "D" then
      item.bufnr = vim.fn.bufadd(("rexr://%s/%s"):format(M.review.base, f.path))
    else
      item.filename = M.review.root .. "/" .. f.path
    end
    items[#items + 1] = item
  end
  local what = { items = items, title = title(), quickfixtextfunc = files_text }
  if M.list_id and vim.fn.getloclist(M.win, { id = M.list_id }).id == M.list_id then
    what.id = M.list_id
    vim.fn.setloclist(M.win, {}, "u", what)
  else
    vim.fn.setloclist(M.win, {}, " ", what)
    M.list_id = vim.fn.getloclist(M.win, { id = 0 }).id
  end
end

--- Take a new set of changed files, sorted as a file browser would.
local function set_files(files)
  table.sort(files, function(x, y)
    return x.path:lower() < y.path:lower()
  end)
  M.files, M.by_path = files, {}
  for _, f in ipairs(files) do
    M.by_path[f.path] = f
  end
  live.watch(
    M.review.root,
    vim.tbl_map(function(f)
      return f.path
    end, files),
    function()
      M.refresh()
    end
  )
  update_list()
end

--- Pick up what changed on disk: which files differ, and their text. Every
--- window keeps its view, and the focus stays where it is.
function M.refresh()
  if not M.review then
    return
  end
  vim.cmd("checktime")
  set_files(git.changed(M.review.base))
  for buf in pairs(M.shown) do
    local wins = vim.tbl_filter(in_tab, vim.fn.win_findbuf(buf))
    if not vim.api.nvim_buf_is_valid(buf) or not file_of(buf) or #wins == 0 then
      -- No longer changed, or out of sight: drawn afresh when shown again.
      clear(buf)
    else
      local views = {}
      for _, w in ipairs(wins) do
        views[w] = vim.api.nvim_win_call(w, vim.fn.winsaveview)
      end
      draw(buf, wins[1])
      for _, w in ipairs(wins) do
        frame(w, buf)
        vim.api.nvim_win_call(w, function()
          vim.fn.winrestview(views[w])
          vim.cmd("normal! zv")
        end)
      end
    end
  end
  update_winbar()
end

--- Where the cursor is, in a file rexr has drawn on.
local function here()
  local buf = vim.api.nvim_get_current_buf()
  local s = M.shown[buf]
  if not s then
    notify("not a changed file in the review")
    return nil
  end
  local side = s.sides.RIGHT == true and "RIGHT" or "LEFT"
  return { side = side, path = s.path, buf = buf, sides = s.sides }
end

--- The threads on lines `l1` to `l2` of the current file.
local function threads_on(h, l1, l2)
  local seen, out = {}, {}
  for l = l1, l2 do
    for _, t in ipairs(comments.at(h.path, h.sides, l)) do
      if not seen[t] then
        seen[t], out[#out + 1] = true, t
      end
    end
  end
  return out
end

--- Ask for a comment in a float; `:w` saves it, `q` drops it.
local function input(name, cb)
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
    title = " " .. name .. " ",
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

--- :[range]Rexr comment
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
    return notify(("%d in chat; press Enter in the agent"):format(#threads))
  end
  local copied = pcall(vim.fn.setreg, "+", text)
  notify(err .. (copied and "; copied instead" or ""), vim.log.levels.WARN)
end

--- :[range]Rexr send, and :[range]Rexr resend for comments already in chat,
--- as when the person cleared the agent's prompt.
function M.send(l1, l2, again)
  local h = here()
  if not h then
    return
  end
  local all = threads_on(h, l1, l2)
  if again then
    return send(all)
  end
  local unsent = vim.tbl_filter(function(t)
    return not t.sent
  end, all)
  if #all > 0 and #unsent == 0 then
    return notify("already in chat; :Rexr resend sends it again")
  end
  send(unsent)
end

--- :Rexr send all: every draft not yet in chat, from every file.
function M.send_all()
  send(comments.find(function(t)
    return t.kind == "draft" and not t.sent
  end))
end

--- :Rexr delete: your draft on the cursor's line.
function M.delete()
  local h = here()
  if not h then
    return
  end
  local drafts = vim.tbl_filter(function(t)
    return t.kind == "draft"
  end, threads_on(h, vim.fn.line("."), vim.fn.line(".")))
  if #drafts == 0 then
    return notify("no draft on this line")
  end
  comments.delete(drafts[#drafts].id)
end

--- :Rexr comments: every comment in a new location list; :lolder goes back
--- to the files.
function M.list_comments()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    return
  end
  local items = {}
  for _, t in ipairs(comments.threads) do
    local f = M.by_path[t.path]
    local item = { lnum = t.start_line or t.line, text = ("%s %s: %s"):format(t.id, t.messages[1].author, t.messages[1].body:match("[^\n]*")) }
    if f and f.status == "D" then
      item.bufnr = vim.fn.bufadd(("rexr://%s/%s"):format(M.review.base, t.path))
    else
      item.filename = M.review.root .. "/" .. t.path
    end
    items[#items + 1] = item
  end
  vim.fn.setloclist(M.win, {}, " ", { title = "rexr comments", items = items })
end

--- Open the threads on the cursor's line in a float; K again enters it.
local function show_threads()
  local h = M.shown[vim.api.nvim_get_current_buf()] and here()
  local threads = h and threads_on(h, vim.fn.line("."), vim.fn.line(".")) or {}
  if #threads == 0 then
    if #vim.lsp.get_clients({ bufnr = 0 }) > 0 then
      return vim.lsp.buf.hover()
    end
    return vim.cmd("normal! K")
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
    max_width = math.min(120, vim.api.nvim_win_get_width(0) - 4),
    max_height = math.floor(vim.o.lines * 0.6),
    focus_id = "rexr.threads",
  })
end

--- ]c and [c: the next or previous change, as in diff mode.
local function change(dir)
  local s = M.shown[vim.api.nvim_get_current_buf()]
  if not (s and in_tab(vim.api.nvim_get_current_win())) then
    return vim.cmd(("normal! %d%s"):format(vim.v.count1, dir > 0 and "]c" or "[c"))
  end
  unified.jump(s.hunks or {}, dir)
end

--- ]d and [d: only rexr's comments, though the person's LSP may put its own
--- diagnostics here. on_jump overrides their global jump config, whose
--- float would repeat K.
local function comment_jump(dir)
  vim.diagnostic.jump({ count = dir * vim.v.count1, namespace = vim.tbl_values(comments.ns), on_jump = function() end })
end

maps = {
  { "n", "]c", function() change(1) end, "rexr: next change" },
  { "n", "[c", function() change(-1) end, "rexr: previous change" },
  { "n", "]d", function() comment_jump(1) end, "rexr: next comment" },
  { "n", "[d", function() comment_jump(-1) end, "rexr: previous comment" },
  { "n", "K", show_threads, "rexr: comments on this line, else hover" },
  { "n", "<localleader>c", "<Cmd>Rexr comment<CR>", "rexr: comment on this line" },
  { "x", "<localleader>c", ":Rexr comment<CR>", "rexr: comment on these lines" },
  { "n", "<localleader>s", "<Cmd>Rexr send<CR>", "rexr: send this line's comments" },
  { "x", "<localleader>s", ":Rexr send<CR>", "rexr: send these lines' comments" },
  { "n", "<localleader>S", "<Cmd>Rexr send all<CR>", "rexr: send all drafts" },
  { "n", "<localleader>x", "<Cmd>Rexr delete<CR>", "rexr: delete your draft here" },
  { "n", "g?", "<Cmd>help rexr<CR>", "rexr: help" },
}

--- End the review: stop following the worktree, the agent and the PR, and
--- take rexr off every buffer. Closes the review's tab when it's open and
--- not the last one.
function M.close()
  if not M.review then
    return
  end
  local tab = M.tab
  M.tab = nil
  live.stop()
  vim.api.nvim_clear_autocmds({ group = group })
  for buf in pairs(M.shown) do
    clear(buf)
  end
  comments.on_change = function() end
  M.review, M.win, M.list_id, M.agent = nil, nil, nil, nil
  M.files, M.by_path, M.shown, M.first = {}, {}, {}, {}
  M.on_refresh = function() end
  if tab and vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
    vim.cmd.tabclose(vim.api.nvim_tabpage_get_number(tab))
  end
end

local function autocmds()
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(ev)
      local win = vim.api.nvim_get_current_win()
      if in_tab(win) and vim.api.nvim_win_get_buf(win) == ev.buf and file_of(ev.buf) then
        if not M.shown[ev.buf] then
          draw(ev.buf, win)
        end
        frame(win, ev.buf)
      end
      if win == M.win then
        update_winbar()
      end
    end,
  })
  -- Removed lines are padded to their window's width.
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      for _, win in ipairs(vim.v.event.windows) do
        local buf = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
        local s = buf and M.shown[buf]
        if s and s.hunks and in_tab(win) then
          unified.render(win, s.hunks, s.before)
        end
      end
    end,
  })
  -- :q in the review window takes its files list along, so the tab closes.
  vim.api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function()
      if vim.api.nvim_get_current_win() == M.win then
        vim.cmd("lclose")
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      if M.tab and not vim.api.nvim_tabpage_is_valid(M.tab) then
        M.close()
      end
    end,
  })
end

--- Open `review` in a tab of its own, or in this one when it's empty, as
--- after `nvim +Rexr`. A review already open closes first.
function M.open(review)
  M.close()
  local buf = vim.api.nvim_get_current_buf()
  local empty = #vim.api.nvim_tabpage_list_wins(0) == 1
    and vim.api.nvim_buf_get_name(buf) == ""
    and not vim.bo[buf].modified
    and vim.api.nvim_buf_line_count(buf) == 1
    and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
  if not empty then
    vim.cmd.tabnew()
  end
  vim.cmd.tcd(vim.fn.fnameescape(review.root))
  M.review = review
  M.tab = vim.api.nvim_get_current_tabpage()
  M.win = vim.api.nvim_get_current_win()
  autocmds()
  comments.on_change = function()
    for b, s in pairs(M.shown) do
      if vim.api.nvim_buf_is_valid(b) then
        comments.render(b, s.path, s.sides)
      end
    end
    update_list()
  end
  set_files(git.changed(review.base))
  -- A third of the tab at most: beside an agent, the diff needs the room.
  local room = math.floor(vim.api.nvim_win_get_height(M.win) / 3)
  vim.cmd(("lopen %d"):format(math.max(math.min(#M.files, room), 3)))
  vim.wo.wrap = false
  vim.api.nvim_set_current_win(M.win)
  if #M.files == 0 then
    return notify("no changes against " .. review.base:sub(1, 8))
  end
  vim.cmd("silent ll 1")
end

return M
