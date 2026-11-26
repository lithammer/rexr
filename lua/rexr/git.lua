local M = {
  -- The repository's root once a review starts. Git runs there, not in
  -- Neovim's working directory, which follows whichever tab is current.
  cwd = nil, ---@type string?
}

---@return string? stdout, string? err
local function run(args)
  local r = vim.system(vim.list_extend({ "git" }, args), { text = true, cwd = M.cwd }):wait()
  if r.code ~= 0 then
    return nil, vim.trim(r.stderr)
  end
  return r.stdout
end

local function lines(text)
  local out = vim.split(text, "\n", { plain = true })
  if out[#out] == "" then
    out[#out] = nil
  end
  return out
end

--- The repository holding Neovim's working directory.
function M.root()
  local r = vim.system({ "git", "rev-parse", "--show-toplevel" }, { text = true }):wait()
  return r.code == 0 and vim.trim(r.stdout) or nil
end

function M.git_dir()
  local out = run({ "rev-parse", "--absolute-git-dir" })
  return out and vim.trim(out)
end

function M.branch()
  local out = run({ "symbolic-ref", "--short", "-q", "HEAD" })
  return out and vim.trim(out) or "detached"
end

---@return string? sha
function M.rev(ref)
  local out = run({ "rev-parse", "--verify", "--quiet", ref .. "^{commit}" })
  return out and vim.trim(out)
end

---@param refs string[] candidates, first that exists wins
---@return string? sha
function M.merge_base(refs)
  for _, ref in ipairs(refs) do
    local out = run({ "merge-base", "HEAD", ref })
    if out then
      return vim.trim(out)
    end
  end
end

function M.is_ancestor(rev, of)
  return run({ "merge-base", "--is-ancestor", rev, of }) ~= nil
end

--- Where this branch forked from the default branch, else HEAD.
function M.default_base()
  return M.merge_base({ "origin/HEAD" }) or M.rev("HEAD")
end

---@class rexr.File
---@field status string one of A M D R C T ?
---@field path string
---@field old? string path in base, for renames and copies

--- Files that differ between base and the worktree, untracked files included.
---@return rexr.File[]
function M.changed(base)
  local files = {}
  local out = run({ "diff", "--name-status", "-z", "-M", base, "--" }) or ""
  local f = vim.split(out, "\0", { plain = true })
  local i = 1
  while f[i] and f[i] ~= "" do
    local status = f[i]:sub(1, 1)
    if status == "R" or status == "C" then
      files[#files + 1] = { status = status, old = f[i + 1], path = f[i + 2] }
      i = i + 3
    else
      files[#files + 1] = { status = status, path = f[i + 1] }
      i = i + 2
    end
  end
  for _, path in ipairs(vim.split(run({ "ls-files", "--others", "--exclude-standard", "-z" }) or "", "\0")) do
    if path ~= "" then
      files[#files + 1] = { status = "?", path = path }
    end
  end
  return files
end

--- A file's lines at a revision, or nil when it doesn't exist there.
---@return string[]?
function M.show(rev, path)
  local out = run({ "show", rev .. ":" .. path })
  if not out then
    return nil
  end
  if out:find("\0", 1, true) then
    return { "(binary file)" }
  end
  return lines(out)
end

return M
