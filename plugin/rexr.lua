vim.api.nvim_create_user_command("Rexr", function(o)
  require("rexr").start(o.fargs)
end, {
  nargs = "*",
  desc = "Review a diff (diff [BASE]) or pull request (pr [N])",
  complete = function(_, line)
    return #vim.split(line, "%s+") <= 2 and { "diff", "pr" } or {}
  end,
})
