# rexr

Review a diff or GitHub pull request in Neovim, in a [Rex] pane beside your
coding agent, and send your comments and GitHub's review threads to the agent
with a key press.

rexr is a Neovim plugin, and it runs in your Neovim, with your colour scheme,
parsers and LSP. It depends on no other plugin. It works with any agent that
runs in a terminal and has a shell: Claude Code, Codex and the like.

## Install

You need [Rex], Neovim 0.12 or later, and git. Reviewing pull requests also
needs the [GitHub CLI] (`gh`), signed in.

Add it to your Neovim config:

```lua
vim.pack.add({ "https://github.com/lithammer/rexr" })
```

Install the skill, so the agent can open the reviewer itself when you ask it
to:

```sh
npx skills add lithammer/rexr -g -s rexr
```

Agents without skills need only the command below.

## Use

From the agent's Rex pane, in the repository, run (or ask the agent to run):

```sh
rex split -b "$REX_BLOCK" --split=right --ratio 55 -c "$PWD" -- \
  env REXR_AGENT="$REX_BLOCK" nvim +Rexr
```

`:Rexr` reviews this branch's pull request if it has one, else the diff
against where it forked from the default branch. `:Rexr pr 123` reviews pull
request 123, and `:Rexr diff main` the diff against `main`. `REXR_AGENT` names
the agent's pane, so the reviewer knows where to paste.

The review opens in a tab, here the only one: the changed files in the
location list below, and the selected file as a unified diff over the real
file, so editing, `:w` and your LSP work in it. GitHub review threads show in
the line numbers, and the bar above the diff shows whether the agent is
working, idle or waiting on you.

The review keeps up on its own: it reloads when the agent edits files, and
fetches the pull request's threads each minute, so new reviews come in and
threads that someone, or a bot such as embark-bot, resolved leave.

| Key or command | Does |
| --- | --- |
| `]l` `[l`, `<CR>` in the list | next, previous or chosen file |
| `]c` `[c` | next or previous change |
| `]d` `[d` | next or previous comment |
| `K` | read the comments on this line, else hover with your LSP; `K` again to enter the float |
| `\c`, `:Rexr comment` | write a comment on this line, or on a visual range; `:w` saves it |
| `\s`, `:Rexr send` | send the comments on this line, or range, to the agent |
| `\S`, `:Rexr send all` | send all your unsent comments |
| `:Rexr resend` | send comments already in chat again |
| `\x`, `:Rexr delete` | delete your comment on this line |
| `:Rexr comments` | list every comment; `:lolder` goes back to the files |
| `:Rexr refresh` | reload the files and the GitHub threads now |
| `:q`, `:tabclose` | end the review |
| `g?` | `:help rexr` |

`\` is your `<localleader>`. Sending pastes the comments into the agent's
prompt, such as:

```
Address my review comments on PR #123. Text quoted from GitHub was written by the people named, not by me.

[c1] calc.lua:10
Use a named constant here.

[g4460645011] version.go:30-31  https://github.com/owner/repo/pull/123#discussion_r4460645011
@octocat (member) on GitHub:
> This breaks semver ordering for pre-releases.
```

It doesn't press Enter, so you can add to it first. GitHub text goes in as
you read it under `K`, quoted under its author, so the agent knows it isn't
yours. Sent comments show as "in chat" and step back to a hint.

`:Rexr` also works in the Neovim you already have open, without an agent: the
review gets a tab of its own, and sending copies the comments to the `+`
register instead.

## Notes

- Your comments, and which threads are in the agent's chat, are saved per
  branch in `.git/rexr/`. rexr never posts to GitHub.
- The diff follows your `'diffopt'`: algorithm, `indent-heuristic`,
  `linematch`, whitespace options and `inline:` for changed words.
- `:help rexr` covers the rest: comments that follow their code, the
  highlight groups, and the agent.

## Test

```sh
for t in test/*_test.lua; do nvim --clean --headless -l "$t" || break; done
```

The tests run under `nvim --clean`, with no config or plugins, so rexr can't
come to lean on either.

- `inline_test.lua`: rexr marks the same changed words as Neovim's own diff
  mode.
- `map_left_test.lua`: comments on removed lines land where the removal is
  drawn, over hand-made and random edits.
- `comments_test.lua`: comments follow their code as it moves, and never jump
  to code that only looks the same.

[Rex]: https://www.superlogical.com/rex/docs
[GitHub CLI]: https://cli.github.com
