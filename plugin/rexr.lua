vim.api.nvim_create_user_command("Rexr", function(o)
  require("rexr").command(o)
end, {
  nargs = "*",
  range = true,
  desc = "Review a diff or pull request, and act on it: see :help rexr",
  complete = function(_, line)
    local words = vim.split(line, "%s+")
    if #words <= 2 then
      return require("rexr").subcommands
    end
    return words[2] == "send" and #words == 3 and { "all" } or {}
  end,
})

-- rexr://REV/PATH is PATH as it was at REV, read-only. A path that doesn't
-- exist at REV reads as empty, which is how added files show their base.
vim.api.nvim_create_autocmd("BufReadCmd", {
  pattern = "rexr://*",
  callback = function(ev)
    local rev, path = ev.match:match("^rexr://([^/]+)/(.+)$")
    if not rev then
      return
    end
    local lines = require("rexr.git").show(rev, path) or {}
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
