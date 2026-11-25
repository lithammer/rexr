---
name: rexr
description: Open the rexr reviewer, a Neovim diff and pull request viewer, in a Rex split beside this agent so the user can review your changes and send comments back to you. Use when the user asks to review the diff, the branch, or a PR in rexr or in a split, or asks to see your changes side by side.
---

# rexr

`rexr` shows a diff or pull request in a clean Neovim in a Rex pane beside
yours. The user reads it there, writes comments, and pastes them into your
prompt.

## Open the reviewer

Run from your own pane, in the repository:

```sh
rexr open          # this branch's PR if it has one, else the diff against the default branch
rexr open pr 123   # a given PR
rexr open diff main
```

It opens the split and returns at once. Don't wait for the review. Tell the
user it's open and carry on, or stop if you have nothing else to do.

## Comments you receive

Comments arrive as a pasted message that starts with `Review comments`. Each
one has an ID in brackets, such as `[c3]` for the user's own comments or
`[g4672637878]` for a GitHub review thread, followed by the file and line and
the code it refers to.

Address each comment. Then answer it so the reviewer shows it as settled:

```sh
rexr reply c3 "Renamed the helper and updated both callers."
```

Keep the answer to a sentence or two about what you changed, or why you
didn't. Replies to GitHub threads stay local to the reviewer. Post to GitHub
only when the user asks.

`rexr reply` fails with "no reviewer is open beside this pane" when the user
has closed it. Then report your answers in your own reply instead.
