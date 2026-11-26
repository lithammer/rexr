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

local last -- the threads as last fetched, or the error
local function fetch_threads(pr)
  local review = view.review
  if not review then
    return
  end
  github.threads(pr, function(nodes, err)
    if view.review ~= review then
      return -- that review has ended, or another took its place
    end
    local now = nodes and vim.inspect(nodes) or err -- inspect sorts keys
    if now == last then
      return -- no change, or the same failure: say it once
    end
    last = now
    if not nodes then
      return fail("cannot load PR comments: " .. err)
    end
    comments.set_github(nodes)
  end)
end

--- :Rexr [diff [BASE] | pr [N]]. With no mode, review this branch's PR if it
--- has one, else the diff against where it forked from the default branch.
---@param args string[]
local function start(args)
  local mode, arg = args[1], args[2]
  local root = git.root()
  if not root then
    return fail("not inside a git repository")
  end
  git.cwd = root
  vim.treesitter.language.register("bash", "sh") -- nvim-treesitter's job, if it's installed
  local review = { root = root, git_dir = git.git_dir() }

  if mode ~= "diff" then
    local pr, err = github.pr(arg, root)
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

  last = nil
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
    live.follow_pr(view.on_refresh)
  end
end

-- What :Rexr does in an open review; see :help rexr-commands.
local actions = {
  comment = function(o)
    view.comment(o.line1, o.line2)
  end,
  send = function(o)
    if o.fargs[2] == "all" then
      return view.send_all()
    end
    view.send(o.line1, o.line2, false)
  end,
  resend = function(o)
    view.send(o.line1, o.line2, true)
  end,
  delete = function()
    view.delete()
  end,
  refresh = function()
    view.refresh()
    view.on_refresh()
  end,
  comments = function()
    view.list_comments()
  end,
}

M.subcommands = vim.list_extend({ "diff", "pr" }, vim.tbl_keys(actions))

--- :Rexr, as plugin/rexr.lua defines it.
---@param o vim.api.keyset.create_user_command.command_args
function M.command(o)
  local sub = o.fargs[1]
  if sub == nil or sub == "diff" or sub == "pr" then
    return start(o.fargs)
  end
  local action = actions[sub]
  if not action then
    return fail(("unknown command %s; see :help rexr-commands"):format(sub))
  end
  if not view.review then
    return fail("no review open; start one with :Rexr")
  end
  action(o)
end

return M
