-- Do comments follow their code as the agent edits the file?
--
--   nvim --clean --headless -l test/comments_test.lua
--
-- Each comment keeps the lines it was written on and, on render, moves to
-- where they now sit (relocate() in lua/rexr/comments.lua). A failure means
-- a comment shown on the wrong line, or one that jumps to code that merely
-- looks the same.

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))
vim.opt.rtp:prepend(root)
local comments = require("rexr.comments")

-- Moved drafts are saved; keep that out of any repository.
comments.review = { git_dir = vim.fn.tempname(), base = "HEAD" }

local failures = 0
local function check(name, cond, detail)
  if not cond then
    failures = failures + 1
    print(("%s: %s"):format(name, detail))
  end
end

--- Render one draft on `code` at `line` (to `upto` for a range) over a buffer
--- holding `now`, and return it with the line its diagnostic landed on.
local function place(code, line, now, opts)
  opts = opts or {}
  local t = {
    id = "c1",
    kind = "draft",
    path = "f.lua",
    side = opts.side or "RIGHT",
    line = opts.upto or line,
    start_line = opts.upto and line or nil,
    code = code,
    messages = { { author = "you", body = "x" } },
  }
  comments.threads = { t }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, now)
  comments.render(buf, "f.lua", opts.sides or { RIGHT = true })
  local d = vim.diagnostic.get(buf)[1]
  vim.api.nvim_buf_delete(buf, { force = true })
  return t, d and d.lnum + 1
end

local file = { "local M = {}", "", "function M.add(a, b)", "  return a + b", "end", "", "return M" }

local t, shown = place({ "  return a + b" }, 4, file)
check("untouched", t.line == 4 and not t.stale and shown == 4, ("at %d, stale %s"):format(t.line, tostring(t.stale)))

local moved = vim.list_extend({ "-- one", "-- two" }, file)
t, shown = place({ "  return a + b" }, 4, moved)
check("lines inserted above", t.line == 6 and not t.stale and shown == 6, ("at %d, want 6"):format(t.line))

local edited = vim.deepcopy(file)
edited[4] = "  return a - b"
t = place({ "  return a + b" }, 4, edited)
check("its line edited", t.line == 4 and t.stale, ("at %d, stale %s"):format(t.line, tostring(t.stale)))

-- A line as short as `end` says too little to follow. The comment's `end`
-- on line 5 is gone and the only one left is on line 3: it must not jump.
t = place({ "end" }, 5, { "x", "y", "end", "z", "w", "v" })
check("short line never jumps", t.line == 5 and t.stale, ("at %d, stale %s"):format(t.line, tostring(t.stale)))

local twice = vim.deepcopy(moved)
table.insert(twice, 2, "  return a + b")
t = place({ "  return a + b" }, 4, twice)
check("code now appears twice", t.line == 4 and t.stale, ("at %d, stale %s"):format(t.line, tostring(t.stale)))

t, shown = place({ "function M.add(a, b)", "  return a + b" }, 3, moved, { upto = 4 })
check(
  "range moves whole",
  t.start_line == 5 and t.line == 6 and not t.stale and shown == 5,
  ("at %s-%d, want 5-6"):format(tostring(t.start_line), t.line)
)

-- A base-side comment shows through the mapping and is never relocated
-- against the new file's text, which doesn't hold its code.
t, shown = place({ "removed text" }, 3, file, {
  side = "LEFT",
  sides = {
    RIGHT = true,
    LEFT = function(line)
      return line + 2
    end,
  },
})
check("base side through mapping", shown == 5 and t.line == 3 and not t.stale, ("shown at %s, want 5"):format(tostring(shown)))

if failures > 0 then
  print(("%d failure(s): comments would show on the wrong lines"):format(failures))
  os.exit(1)
end
print("ok: comments follow their code")
