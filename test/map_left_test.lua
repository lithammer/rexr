-- Does map_left put base lines where they show in the new file?
--
--   nvim --clean --headless -l test/map_left_test.lua
--
-- The unified view shows the worktree file, and comments on the base side,
-- such as GitHub threads on removed lines, are placed by map_left (in
-- lua/rexr/unified.lua). A failure puts those comments on the wrong line.

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))
vim.opt.rtp:prepend(root)
local unified = require("rexr.unified")

local failures = 0
local function fail(msg)
  failures = failures + 1
  print(msg)
end

-- Hunks in vim.text.diff's terms: { start_a, count_a, start_b, count_b }.
local cases = {
  { "two lines inserted after base 5", { { 5, 0, 6, 2 } }, { [5] = 5, [6] = 8 } },
  { "base 6-7 removed after new 5", { { 6, 2, 5, 0 } }, { [6] = 5, [7] = 5, [8] = 6 } },
  { "base 3 became new 3-4", { { 3, 1, 3, 2 } }, { [2] = 2, [3] = 3, [4] = 5 } },
  { "first line removed", { { 1, 1, 0, 0 } }, { [1] = 1, [2] = 1 } },
  { "two hunks add up", { { 2, 0, 3, 1 }, { 5, 1, 6, 3 } }, { [2] = 2, [3] = 4, [5] = 6, [6] = 9 } },
}
for _, c in ipairs(cases) do
  for line, want in pairs(c[3]) do
    local got = unified.map_left(c[2], line)
    if got ~= want then
      fail(("%s: base %d maps to %d, want %d"):format(c[1], line, got, want))
    end
  end
end

-- Random edits: every base line that survives must map to a line holding
-- the same text, in order; every removed line to where its removal is drawn.
math.randomseed(1)
local words = { "a", "b", "c", "local x = 1", "}", "", "return y" }
local function random_file(n)
  local lines = {}
  for i = 1, n do
    lines[i] = words[math.random(#words)]
  end
  return lines
end
local function edit(lines)
  local out = vim.deepcopy(lines)
  for _ = 1, math.random(1, 4) do
    local at = math.random(1, #out + 1)
    local op = math.random(3)
    if op == 1 then
      table.insert(out, at, words[math.random(#words)])
    elseif op == 2 and out[at] then
      table.remove(out, at)
    elseif out[at] then
      out[at] = words[math.random(#words)] .. "!"
    end
  end
  return out
end

for run = 1, 500 do
  local before = random_file(math.random(0, 20))
  local after = edit(before)
  local hunks = unified.hunks(before, after)
  local removed = {}
  for _, h in ipairs(hunks) do
    for l = h[1], h[1] + h[2] - 1 do
      removed[l] = math.max(h[3], 1)
    end
  end
  local last = 0
  for l = 1, #before do
    local got = unified.map_left(hunks, l)
    if removed[l] then
      if got ~= removed[l] then
        fail(("run %d: removed base line %d maps to %d, want %d"):format(run, l, got, removed[l]))
      end
    elseif after[got] ~= before[l] or got <= last then
      fail(("run %d: base line %d %q maps to %d %q"):format(run, l, before[l], got, after[got] or "(none)"))
    else
      last = got
    end
  end
end

if failures > 0 then
  print(("%d failure(s): base-side comments would sit on the wrong lines"):format(failures))
  os.exit(1)
end
print("ok: map_left places base lines correctly")
