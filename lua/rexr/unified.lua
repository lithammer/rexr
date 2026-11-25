-- A unified diff drawn over the worktree file itself: added lines tinted,
-- removed lines as virtual lines where they were, unchanged runs folded.
-- The buffer stays the real file, so treesitter, line numbers and comments
-- work on it as on any other.
local M = {}

local ns = vim.api.nvim_create_namespace("rexr.diff")
local CONTEXT = 3

-- Tint changed lines with the colour scheme's diff backgrounds alone. Its
-- DiffAdd may also set a foreground (the default one does), which would
-- paint over the syntax colours. The default DiffDelete has no background:
-- red text, no tint; fall back to the default palette's red then.
local function tints()
  local function bg(name)
    return vim.api.nvim_get_hl(0, { name = name, link = false }).bg
  end
  local dark = vim.o.background ~= "light"
  vim.api.nvim_set_hl(0, "RexrAdded", { bg = bg("DiffAdd") or (dark and "NvimDarkGreen" or "NvimLightGreen") })
  vim.api.nvim_set_hl(0, "RexrRemoved", { bg = bg("DiffDelete") or (dark and "NvimDarkRed" or "NvimLightRed") })
end
tints()
vim.api.nvim_create_autocmd("ColorScheme", { callback = tints })
vim.api.nvim_create_autocmd("OptionSet", { pattern = "background", callback = tints })

---@alias rexr.Hunk integer[] { start_a, count_a, start_b, count_b }, as vim.text.diff gives them

local function text(lines)
  return #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
end

--- vim.text.diff's options for the person's 'diffopt', so the hunks match
--- what :diffthis would show.
local function diffopt()
  local opts = { result_type = "indices" }
  local flags = {
    ["indent-heuristic"] = "indent_heuristic",
    iwhite = "ignore_whitespace_change",
    iwhiteall = "ignore_whitespace",
    iwhiteeol = "ignore_whitespace_change_at_eol",
    iblank = "ignore_blank_lines",
  }
  for _, item in ipairs(vim.opt.diffopt:get()) do
    local key, value = item:match("^([^:]+):?(.*)$")
    if flags[key] then
      opts[flags[key]] = true
    elseif key == "algorithm" then
      opts.algorithm = value
    elseif key == "linematch" then
      opts.linematch = tonumber(value)
    end
  end
  return opts
end

---@return rexr.Hunk[]
function M.hunks(before, after)
  return vim.text.diff(text(before), text(after), diffopt())
end

--- The worktree line where base line `line` shows. A hunk with no lines on
--- one side starts after the line its start names, so it covers nothing of
--- that side; a removed line shows where its removal is drawn.
function M.map_left(hunks, line)
  local delta = 0
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    local first = ca == 0 and sa + 1 or sa
    if line < first then
      break
    end
    if line < first + ca then
      return math.max(sb, 1)
    end
    delta = (cb == 0 and sb + 1 or sb + cb) - (first + ca)
  end
  return line + delta
end

--- The first worktree line of each hunk, or the line its removal is drawn at.
local function starts(hunks)
  return vim.tbl_map(function(h)
    return math.max(h[3], 1)
  end, hunks)
end

-- Virtual lines show tabs as one cell; expand them as the buffer would,
-- from display column `col`.
local function expand(s, ts, col)
  local out = {}
  for seg, tab in s:gmatch("([^\t]*)(\t?)") do
    out[#out + 1] = seg
    col = col + vim.fn.strdisplaywidth(seg)
    if tab ~= "" then
      local n = ts - col % ts
      out[#out + 1] = string.rep(" ", n)
      col = col + n
    end
  end
  return table.concat(out), col
end

--- Syntax colours for the base lines in `ranges`, from a treesitter parse
--- of the whole base file, so a removed line is read in its context and not
--- as a fragment. Spans per line: { first byte, past the last, group }.
---@param ranges integer[][] { first, last } base lines, 1-based
---@return table<integer, {[1]: integer, [2]: integer, [3]: string}[]>
local function syntax(before, ft, ranges)
  local lang = ft ~= "" and vim.treesitter.language.get_lang(ft)
  local query = lang and vim.treesitter.query.get(lang, "highlights")
  if not query or #ranges == 0 then
    return {}
  end
  local src = table.concat(before, "\n")
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
  if not ok then
    return {}
  end
  local root = parser:parse()[1]:root()
  local spans = {}
  for _, r in ipairs(ranges) do
    for id, node in query:iter_captures(root, src, r[1] - 1, r[2]) do
      local name = query.captures[id]
      if not name:match("^_") and name ~= "spell" and name ~= "nospell" then
        local sr, sc, er, ec = node:range()
        for row = math.max(sr, r[1] - 1), math.min(er, r[2] - 1) do
          local line = row + 1
          spans[line] = spans[line] or {}
          table.insert(spans[line], { row == sr and sc or 0, row == er and ec or #before[line], "@" .. name .. "." .. lang })
        end
      end
    end
  end
  return spans
end

--- A removed line as virtual text chunks: its syntax colours over the
--- removed tint, tabs expanded, padded to `width` so the tint spans the line.
local function chunks(line, spans, ts, width)
  local group = {}
  for _, sp in ipairs(spans or {}) do
    for c = sp[1] + 1, math.min(sp[2], #line) do
      group[c] = sp[3] -- later captures are the more specific ones
    end
  end
  local out, col, i = {}, 0, 1
  while i <= #line do
    local j = i
    while j < #line and group[j + 1] == group[i] do
      j = j + 1
    end
    local seg
    seg, col = expand(line:sub(i, j), ts, col)
    out[#out + 1] = { seg, group[i] and { "RexrRemoved", group[i] } or "RexrRemoved" }
    i = j + 1
  end
  out[#out + 1] = { string.rep(" ", math.max(width - col, 0)), "RexrRemoved" }
  return out
end

--- Draw `hunks` in `win`'s buffer, whose text is the diff's after side.
function M.render(win, hunks, before)
  local buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local textoff = vim.fn.getwininfo(win)[1].textoff
  local width = vim.api.nvim_win_get_width(win) - textoff
  local gutter = { string.rep(" ", math.max(textoff - 2, 0)) .. "- ", "RexrRemoved" }
  local ts = vim.bo[buf].tabstop
  local last = vim.api.nvim_buf_line_count(buf)
  local removed = {}
  for _, h in ipairs(hunks) do
    if h[2] > 0 then
      removed[#removed + 1] = { h[1], h[1] + h[2] - 1 }
    end
  end
  local spans = syntax(before, vim.bo[buf].filetype, removed)
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    for row = sb, sb + cb - 1 do
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { line_hl_group = "RexrAdded" })
    end
    if ca > 0 then
      local virt = {}
      for l = sa, sa + ca - 1 do
        virt[#virt + 1] = { gutter, unpack(chunks(before[l] or "", spans[l], ts, width)) }
      end
      -- Above the hunk's added lines, or below the line the removal follows.
      vim.api.nvim_buf_set_extmark(buf, ns, math.min(math.max(sb, 1), last) - 1, 0, {
        virt_lines = virt,
        virt_lines_above = cb > 0 or sb == 0,
        virt_lines_leftcol = true,
      })
    end
  end
end

--- Draw a buffer whose every line was removed.
function M.render_removed(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for row = 0, vim.api.nvim_buf_line_count(buf) - 1 do
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = "RexrRemoved" })
  end
end

--- Fold what lies more than CONTEXT lines from any change; nothing when
--- `hunks` is nil.
function M.fold(win, hunks)
  vim.api.nvim_win_call(win, function()
    vim.wo.foldmethod = "manual"
    vim.cmd("normal! zE")
    if not hunks then
      return
    end
    local last = vim.fn.line("$")
    local from = 1
    for _, h in ipairs(hunks) do
      local first = math.max(h[3], 1)
      local upto = h[4] > 0 and h[3] + h[4] - 1 or first
      if first - CONTEXT - from >= 2 then
        vim.cmd(("%d,%dfold"):format(from, first - CONTEXT - 1))
      end
      from = math.max(from, upto + CONTEXT + 1)
    end
    if last - from >= 1 then
      vim.cmd(("%d,%dfold"):format(from, last))
    end
  end)
end

--- Move the cursor to the next (`dir` 1) or previous (-1) hunk.
function M.jump(hunks, dir)
  local cur = vim.fn.line(".")
  local rows = starts(hunks)
  for i = dir > 0 and 1 or #rows, dir > 0 and #rows or 1, dir do
    if (dir > 0 and rows[i] > cur) or (dir < 0 and rows[i] < cur) then
      vim.api.nvim_win_set_cursor(0, { rows[i], 0 })
      vim.cmd("normal! zv")
      return
    end
  end
end

--- The first hunk's line, to open a file at.
function M.first(hunks)
  return starts(hunks)[1] or 1
end

return M
