-- A unified diff drawn over the worktree file itself: added lines tinted,
-- removed lines as virtual lines where they were, unchanged runs folded.
-- The buffer stays the real file, so treesitter, line numbers and comments
-- work on it as on any other.
local M = {}

local ns = vim.api.nvim_create_namespace("rexr.diff")
local CONTEXT = 3
-- Above treesitter's highlights, whose foregrounds still show through the
-- background-only tints; a changed word's tint sits one above its line's.
local TINT = 4000

-- How much of DiffAdd or DiffDelete a changed line's tint takes, the rest
-- being Normal's background; changed words take all of it. Schemes made for
-- :diffthis paint DiffAdd strong, as jellybeans' #437019, which over whole
-- blocks of new code drowns the syntax. diffs.nvim mixes the same way.
local MIX = 0.6

local function mix(c, base)
  local out = 0
  for shift = 16, 0, -8 do
    local a, b = bit.band(bit.rshift(c, shift), 0xff), bit.band(bit.rshift(base, shift), 0xff)
    out = bit.bor(out, bit.lshift(math.floor(a * MIX + b * (1 - MIX) + 0.5), shift))
  end
  return out
end

-- Tint with backgrounds alone, so syntax colours show through. Changed words
-- take the line's colour at full strength rather than DiffText, which some
-- schemes mark by foreground alone, jellybeans with a black background. The
-- default DiffDelete has no background, so fall back to the default palette.
local function tints()
  local function bg(name, fallback)
    return vim.api.nvim_get_hl(0, { name = name, link = false }).bg or vim.api.nvim_get_color_by_name(fallback)
  end
  local dark = vim.o.background ~= "light"
  local base = bg("Normal", dark and "NvimDarkGrey2" or "NvimLightGrey2")
  local add = bg("DiffAdd", dark and "NvimDarkGreen" or "NvimLightGreen")
  local del = bg("DiffDelete", dark and "NvimDarkRed" or "NvimLightRed")
  vim.api.nvim_set_hl(0, "RexrAdded", { bg = mix(add, base) })
  vim.api.nvim_set_hl(0, "RexrAddedText", { bg = add })
  vim.api.nvim_set_hl(0, "RexrRemoved", { bg = mix(del, base) })
  vim.api.nvim_set_hl(0, "RexrRemovedText", { bg = del })
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

--- How 'diffopt' marks changes within a line: none, simple, char or word.
local function inline_mode()
  for _, item in ipairs(vim.opt.diffopt:get()) do
    local mode = item:match("^inline:(%a+)$")
    if mode then
      return mode
    end
  end
  return "simple"
end

-- Longer lines, such as minified code, aren't worth a token diff.
local MAX_INLINE = 2000

--- A line cut into tokens { text, first byte (0-based), past the last }:
--- one per character, or for words, as 'diffopt' defines them: runs of
--- word characters ('iskeyword') or of blanks, any other character alone,
--- emoji and CJK included.
local function tokens(line, mode)
  local out = {}
  local pos = vim.str_utf_pos(line)
  for i, p in ipairs(pos) do
    local e = (pos[i + 1] or #line + 1) - 1
    local c = line:sub(p, e)
    local class = mode == "word" and vim.fn.charclass(c) or nil
    local prev = out[#out]
    if prev and (class == 0 or class == 2) and prev.class == class then
      prev[1], prev[3] = prev[1] .. c, e
    else
      out[#out + 1] = { c, p - 1, e, class = class }
    end
  end
  return out
end

--- Join changed ranges split by a short run of non-word characters, as
--- 'diffopt' inline:word does for gaps of five bytes or less.
local function merge(ranges, line)
  local out = {}
  for _, r in ipairs(ranges) do
    local prev = out[#out]
    local gap = prev and line:sub(prev[2] + 1, r[1])
    if gap and #gap <= 5 and not gap:find("[%w_]") then
      prev[2] = r[2]
    else
      out[#out + 1] = { r[1], r[2] }
    end
  end
  return out
end

--- Merge character changes split by a short run of unchanged characters,
--- as Neovim's diff mode does for inline:char, which a naive character
--- diff otherwise leaves as scattered fragments ("re|rn" for "return"):
--- a gap of three characters or less goes when the larger side of the two
--- changes it splits is at least four times as long. A merge can make a
--- neighbouring gap worth merging, so pass again, a few times at most.
local function refine(blocks)
  for _ = 1, 4 do
    local merged, unmerged = false, false
    local i = 1
    while i < #blocks do
      local k, n = blocks[i], blocks[i + 1]
      local gap = n[1] - (k[1] + k[2])
      if gap <= 3 and math.max(k[2] + n[2], k[4] + n[4]) >= gap * 4 then
        k[2] = n[1] + n[2] - k[1]
        k[4] = n[3] + n[4] - k[3]
        table.remove(blocks, i + 1)
        merged = true
      else
        unmerged = unmerged or gap <= 3
        i = i + 1
      end
    end
    if not (merged and unmerged) then
      break
    end
  end
  return blocks
end

--- The changed byte ranges { first, past the last } of a removed line and
--- the added line it became. Neovim keeps its own inline diff inside diff
--- mode, so diff the lines' tokens with the same engine, one per line.
local function inline(old, new, mode)
  if #old > MAX_INLINE or #new > MAX_INLINE then
    return {}, {}
  end
  if mode == "simple" then
    local p, s = 0, 0
    while p < #old and p < #new and old:byte(p + 1) == new:byte(p + 1) do
      p = p + 1
    end
    while s < #old - p and s < #new - p and old:byte(#old - s) == new:byte(#new - s) do
      s = s + 1
    end
    return { { p, #old - s } }, { { p, #new - s } }
  end
  local a, b = tokens(old, mode), tokens(new, mode)
  local function join(t)
    return text(vim.tbl_map(function(k)
      return k[1]
    end, t))
  end
  -- Each hunk as { first old token, count, first new token, count }: an
  -- empty side's start names the token before it.
  local blocks = vim.tbl_map(function(h)
    return { h[2] == 0 and h[1] + 1 or h[1], h[2], h[4] == 0 and h[3] + 1 or h[3], h[4] }
  end, vim.text.diff(join(a), join(b), { result_type = "indices" }))
  if mode == "char" then
    blocks = refine(blocks)
  end
  local ra, rb = {}, {}
  for _, k in ipairs(blocks) do
    if k[2] > 0 then
      ra[#ra + 1] = { a[k[1]][2], a[k[1] + k[2] - 1][3] }
    end
    if k[4] > 0 then
      rb[#rb + 1] = { b[k[3]][2], b[k[3] + k[4] - 1][3] }
    end
  end
  if mode == "word" then
    return merge(ra, old), merge(rb, new)
  end
  return ra, rb
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
--- removed tint, its `changed` byte ranges tinted as changed words, tabs
--- expanded, padded to `width` so the tint spans the line.
local function chunks(line, spans, ts, width, changed)
  local group, hot = {}, {}
  for _, sp in ipairs(spans or {}) do
    for c = sp[1] + 1, math.min(sp[2], #line) do
      group[c] = sp[3] -- later captures are the more specific ones
    end
  end
  for _, r in ipairs(changed or {}) do
    for c = r[1] + 1, math.min(r[2], #line) do
      hot[c] = true
    end
  end
  local out, col, i = {}, 0, 1
  while i <= #line do
    local j = i
    while j < #line and group[j + 1] == group[i] and hot[j + 1] == hot[i] do
      j = j + 1
    end
    local seg
    seg, col = expand(line:sub(i, j), ts, col)
    -- Stacked groups: the last one's background wins, the syntax colour stays.
    local hl = { "RexrRemoved" }
    if group[i] then
      hl[#hl + 1] = group[i]
    end
    if hot[i] then
      hl[#hl + 1] = "RexrRemovedText"
    end
    out[#out + 1] = { seg, hl }
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
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local mode = inline_mode()
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    -- A range, not line_hl_group: a line highlight draws over every
    -- character highlight, the changed-word tint below included.
    for row = sb, sb + cb - 1 do
      -- Ending at the next line's start covers the line break, which
      -- hl_eol needs to carry the tint to the window's edge.
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
        end_row = row,
        end_col = 0,
        hl_group = "RexrAdded",
        hl_eol = true,
        priority = TINT,
        strict = false,
      })
    end
    -- Pair removed and added lines in order, as linematch has aligned them;
    -- lines beyond the shorter side are wholly removed or added.
    local changed = {}
    if mode ~= "none" then
      for k = 0, math.min(ca, cb) - 1 do
        local old_ranges, new_ranges = inline(before[sa + k] or "", after[sb + k] or "", mode)
        changed[sa + k] = old_ranges
        for _, r in ipairs(new_ranges) do
          if r[2] > r[1] then
            vim.api.nvim_buf_set_extmark(buf, ns, sb + k - 1, r[1], {
              end_col = r[2],
              hl_group = "RexrAddedText",
              priority = TINT + 1,
            })
          end
        end
      end
    end
    if ca > 0 then
      local virt = {}
      for l = sa, sa + ca - 1 do
        virt[#virt + 1] = { gutter, unpack(chunks(before[l] or "", spans[l], ts, width, changed[l])) }
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
