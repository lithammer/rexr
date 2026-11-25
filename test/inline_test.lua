-- Do rexr's changed-word marks match Neovim's own diff mode?
--
--   nvim --clean --headless -l test/inline_test.lua
--
-- Neovim marks the changed part of a line only in diff mode and gives Lua
-- no way to read those ranges, so rexr computes them itself (inline() and
-- refine() in lua/rexr/unified.lua). This runs each line pair through both,
-- in each 'diffopt' inline mode, and reads Neovim's marks with diff_hlID.

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))
vim.opt.rtp:prepend(root)
local unified = require("rexr.unified")

local cases = {
  { "return format(version, buildDate, debug.Enabled)", "output := format(version, buildDate, debug.Enabled)" },
  { "local x = oldName + 1", "local x = newName + 1" },
  { "foo(bar, baz)", "foo(baz, bar)" },
  { "if err != nil { return err }", 'if err != nil { return fmt.Errorf("wrap: %w", err) }' },
  { "const timeout = 30 * time.Second", "const timeout = 45 * time.Second" },
  { "hello world", "goodbye world" },
  { "abcdefghij", "abXdefYhij" },
  { "The quick brown fox", "The quack brown fix" },
  { "call(foo, bar) -- 😀 ok", "call(baz, qux) -- 🎉 ok" },
  { "x = a + b", "x = a - b" },
  { "configure(retries=3, backoff=1.5)", "configure(retries=5, backoff=2.0, jitter=True)" },
  { "    }", "    })" },
  { "func Set(service, user, secret string) error {", "func Set(service, user, password string, opts ...Option) error {" },
}

-- Each line sits between unchanged lines, so both sides see one changed line.
local function file(line)
  return { "ctx", line, "ctx" }
end

--- The runs of `line` that diff mode highlights as DiffText or DiffTextAdd.
local function marked(win, line)
  local runs, run = {}, ""
  vim.api.nvim_win_call(win, function()
    for col = 1, #line do
      if vim.fn.synIDattr(vim.fn.diff_hlID(2, col), "name"):match("^DiffText") then
        run = run .. line:sub(col, col)
      elseif run ~= "" then
        runs[#runs + 1], run = run, ""
      end
    end
  end)
  runs[#runs + 1] = run ~= "" and run or nil
  return table.concat(runs, "|")
end

local function neovim(old, new)
  vim.cmd("silent! %bwipeout!")
  local a, b = vim.api.nvim_create_buf(true, true), vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(a, 0, -1, false, file(old))
  vim.api.nvim_buf_set_lines(b, 0, -1, false, file(new))
  vim.api.nvim_set_current_buf(a)
  vim.cmd("diffthis")
  local wa = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  vim.api.nvim_set_current_buf(b)
  vim.cmd("diffthis")
  local wb = vim.api.nvim_get_current_win()
  vim.cmd("diffupdate")
  local got = { marked(wa, old), marked(wb, new) }
  vim.cmd("diffoff! | only")
  return got
end

local function rexr(old, new)
  vim.cmd("silent! %bwipeout!")
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, file(new))
  unified.render(vim.api.nvim_get_current_win(), unified.hunks(file(old), file(new)), file(old))
  local removed, added = {}, {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    if m[4].hl_group == "RexrAddedText" then
      added[#added + 1] = new:sub(m[3] + 1, m[4].end_col)
    end
    for _, virt in ipairs(m[4].virt_lines or {}) do
      for _, chunk in ipairs(virt) do
        if type(chunk[2]) == "table" and vim.tbl_contains(chunk[2], "RexrRemovedText") then
          removed[#removed + 1] = chunk[1]
        end
      end
    end
  end
  return { table.concat(removed, "|"), table.concat(added, "|") }
end

local failures = 0
for _, mode in ipairs({ "simple", "char", "word" }) do
  vim.o.diffopt = "internal,filler,closeoff,indent-heuristic,linematch:40,inline:" .. mode
  for _, case in ipairs(cases) do
    local want, got = neovim(case[1], case[2]), rexr(case[1], case[2])
    if want[1] ~= got[1] or want[2] ~= got[2] then
      failures = failures + 1
      print(("inline:%s %q -> %q"):format(mode, case[1], case[2]))
      print(("  neovim marks old %q, new %q"):format(want[1], want[2]))
      print(("  rexr   marks old %q, new %q"):format(got[1], got[2]))
    end
  end
end

if failures > 0 then
  -- Either rexr's inline() or refine() broke, or Neovim changed its rules.
  print(("%d case(s) where rexr's changed-word marks differ from Neovim's diff mode"):format(failures))
  os.exit(1)
end
print(("ok: %d cases match Neovim's diff mode"):format(3 * #cases))
