-- A unified diff drawn over the worktree file itself: added lines tinted,
-- removed lines as virtual lines where they were, unchanged runs folded.
-- The buffer stays the real file, so treesitter, line numbers and comments
-- work on it as on any other.
local M = {}

local ns = vim.api.nvim_create_namespace("rexr.diff")
local CONTEXT = 3

-- The default DiffDelete is red text on no background; tint removed lines
-- the way DiffAdd tints added ones.
vim.api.nvim_set_hl(0, "RexrRemoved", {
  default = true,
  bg = vim.o.background == "light" and "NvimLightRed" or "NvimDarkRed",
})

---@alias rexr.Hunk integer[] { start_a, count_a, start_b, count_b }, as vim.text.diff gives them

local function text(lines)
  return #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
end

---@return rexr.Hunk[]
function M.hunks(before, after)
  return vim.text.diff(text(before), text(after), { result_type = "indices", algorithm = "histogram" })
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

-- Virtual lines show tabs as one cell; expand them as the buffer would.
local function expand(s, ts)
  local out, col = {}, 0
  for seg, tab in s:gmatch("([^\t]*)(\t?)") do
    out[#out + 1] = seg
    col = col + vim.fn.strdisplaywidth(seg)
    if tab ~= "" then
      local n = ts - col % ts
      out[#out + 1] = string.rep(" ", n)
      col = col + n
    end
  end
  return table.concat(out)
end

--- Draw `hunks` in `win`'s buffer, whose text is the diff's after side.
function M.render(win, hunks, before)
  local buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local textoff = vim.fn.getwininfo(win)[1].textoff
  local width = vim.api.nvim_win_get_width(win) - textoff
  local gutter = string.rep(" ", math.max(textoff - 2, 0)) .. "- "
  local ts = vim.bo[buf].tabstop
  local last = vim.api.nvim_buf_line_count(buf)
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    for row = sb, sb + cb - 1 do
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { line_hl_group = "DiffAdd" })
    end
    if ca > 0 then
      local virt = {}
      for l = sa, sa + ca - 1 do
        local s = expand(before[l] or "", ts)
        local pad = string.rep(" ", math.max(width - vim.fn.strdisplaywidth(s), 0))
        virt[#virt + 1] = { { gutter, "RexrRemoved" }, { s .. pad, "RexrRemoved" } }
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
