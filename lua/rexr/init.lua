local git = require("rexr.git")
local github = require("rexr.github")
local comments = require("rexr.comments")
local view = require("rexr.view")
local agent = require("rexr.agent")
local live = require("rexr.live")

local M = {}

local function fail(msg)
  vim.notify("rexr: " .. msg, vim.log.levels.ERROR)
end

local function fetch_threads(pr)
  github.threads(pr, function(nodes, err)
    if not nodes then
      return fail("cannot load PR comments: " .. err)
    end
    comments.set_github(nodes)
  end)
end

--- :Rexr [diff [BASE] | pr [N]]. With no mode, review this branch's PR if it
--- has one, else the diff against where it forked from the default branch.
---@param args string[]
function M.start(args)
  local mode, arg = args[1], args[2]
  if mode and mode ~= "diff" and mode ~= "pr" then
    return fail("unknown mode " .. mode .. "; want diff or pr")
  end
  local root = git.root()
  if not root then
    return fail("not inside a git repository")
  end
  vim.cmd.cd(root)
  -- --clean still shares the user's swap directory, and a swap file from
  -- their own editor makes bufload fail with E325. The reviewer doesn't edit.
  vim.o.swapfile = false
  -- Borrow the user's installed treesitter parsers and queries. Startup has
  -- already sourced plugin/ files, so adding the directory now runs none of
  -- its plugin code.
  vim.opt.rtp:append(vim.fn.stdpath("data") .. "/site")
  vim.treesitter.language.register("bash", "sh") -- nvim-treesitter's job, absent here
  vim.opt.diffopt:append("foldcolumn:0")
  local review = { root = root, git_dir = git.git_dir() }

  if mode ~= "diff" then
    local pr, err = github.pr(arg)
    if pr then
      review.pr = pr
      review.base = git.merge_base({ "origin/" .. pr.baseRefName, pr.baseRefName })
      if not review.base then
        return fail(("no merge base with %s; try git fetch"):format(pr.baseRefName))
      end
      -- Commits on top of the PR are fine; a checkout without its head is
      -- some other branch, and its diff isn't the PR's.
      if not git.rev(pr.headRefOid) then
        vim.notify("rexr: PR head not fetched; comments may sit on the wrong lines", vim.log.levels.WARN)
      elseif not git.is_ancestor(pr.headRefOid, "HEAD") then
        vim.notify(("rexr: HEAD doesn't contain PR #%d; run gh pr checkout %d"):format(pr.number, pr.number), vim.log.levels.WARN)
      end
    elseif mode == "pr" then
      return fail(err)
    end
  end
  if not review.base then
    review.base = arg and git.rev(arg) or (not arg and git.default_base())
    if not review.base then
      return fail("unknown revision " .. tostring(arg))
    end
  end

  comments.setup(review)
  view.open(review)
  if agent.block then
    live.follow_agent(agent.block, view.set_agent)
  end
  if review.pr then
    view.on_refresh = function()
      fetch_threads(review.pr)
    end
    fetch_threads(review.pr)
    live.follow_pr(review.pr, view.on_refresh)
  end
end

--- Entry point for `rexr reply`: the file holds the comment ID on its first
--- line and the reply after it.
---@return string "ok" or why the reply was refused
function M.reply_file(path)
  local lines = vim.fn.readfile(path)
  local id = table.remove(lines, 1)
  return comments.reply(id, table.concat(lines, "\n"))
end

return M
