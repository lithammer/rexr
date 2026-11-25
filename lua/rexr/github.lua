local M = {}

local QUERY = [[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes {
          isResolved isOutdated path diffSide
          line startLine originalLine originalStartLine
          comments(first: 50) { nodes { databaseId author { login } authorAssociation body url } }
        }
      }
    }
  }
}]]

---@class rexr.PR
---@field number integer
---@field title string
---@field url string
---@field headRefOid string
---@field baseRefName string

--- The pull request numbered `number`, or the current branch's.
---@return rexr.PR?, string? err
function M.pr(number)
  local cmd = { "gh", "pr", "view" }
  if number then
    cmd[#cmd + 1] = tostring(number)
  end
  vim.list_extend(cmd, { "--json", "number,title,url,headRefOid,baseRefName" })
  local ok, r = pcall(function()
    return vim.system(cmd, { text = true }):wait()
  end)
  if not ok then
    return nil, "gh is not installed"
  end
  if r.code ~= 0 then
    return nil, vim.trim(r.stderr)
  end
  return vim.json.decode(r.stdout)
end

--- Fetch the PR's review threads; calls back on the main loop.
---@param pr rexr.PR
---@param cb fun(nodes: table[]?, err: string?)
function M.threads(pr, cb)
  local owner, name = pr.url:match("github%.com/([^/]+)/([^/]+)/pull/")
  local cmd = {
    "gh", "api", "graphql",
    "-f", "owner=" .. owner,
    "-f", "name=" .. name,
    "-F", "number=" .. pr.number,
    "-f", "query=" .. QUERY,
  }
  vim.system(cmd, { text = true }, function(r)
    vim.schedule(function()
      if r.code ~= 0 then
        return cb(nil, vim.trim(r.stderr))
      end
      local data = vim.json.decode(r.stdout)
      cb(data.data.repository.pullRequest.reviewThreads.nodes)
    end)
  end)
end

return M
