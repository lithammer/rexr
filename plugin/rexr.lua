vim.api.nvim_create_user_command("Rexr", function(o)
  require("rexr").start(o.fargs)
end, {
  nargs = "*",
  desc = "Review a diff (diff [BASE]) or pull request (pr [N])",
  complete = function(_, line)
    return #vim.split(line, "%s+") <= 2 and { "diff", "pr" } or {}
  end,
})

-- rexr://REV/PATH is PATH as it was at REV, read-only. A path that doesn't
-- exist at REV reads as empty, which is how added files show their base.
-- rexr://deleted/PATH is the empty worktree side of a deleted file.
vim.api.nvim_create_autocmd("BufReadCmd", {
  pattern = "rexr://*",
  callback = function(ev)
    local rev, path = ev.match:match("^rexr://([^/]+)/(.+)$")
    if not rev then
      return
    end
    local lines = rev ~= "deleted" and require("rexr.git").show(rev, path) or {}
    local bo = vim.bo[ev.buf]
    bo.buftype = "nofile"
    bo.swapfile = false
    bo.modifiable = true
    vim.api.nvim_buf_set_lines(ev.buf, 0, -1, false, lines)
    bo.modifiable = false
    bo.modified = false
    bo.filetype = vim.filetype.match({ filename = path, contents = lines }) or ""
  end,
})
