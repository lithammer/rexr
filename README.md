# rexr

Review a diff or GitHub pull request in Neovim, in a [Rex] pane beside your
coding agent, and send your comments and GitHub's review threads to the agent
with a key press.

rexr runs as `nvim --clean` with this repository on its runtimepath, so your
Neovim config and plugins don't affect it. It works with any agent that runs in
a terminal and has a shell: Claude Code, Codex and the like.

## Install

You need [Rex], Neovim 0.12 or later, and git. Reviewing pull requests also
needs the [GitHub CLI] (`gh`), signed in.

Clone this repository and put `bin/rexr` on your `PATH`:

```sh
git clone <this repository> ~/src/rexr
ln -s ~/src/rexr/bin/rexr ~/.local/bin/rexr
```

For Claude Code, also link the skill, so the agent can open the reviewer
itself when you ask it to:

```sh
ln -s ~/src/rexr/skills/rexr ~/.claude/skills/rexr
```

Other agents need no setup.

## Use

From the agent's Rex pane, in the repository, run (or ask the agent to run):

```sh
rexr open          # this branch's pull request if it has one, else the diff
                   # against where it forked from the default branch
rexr open pr 123   # pull request 123
rexr open diff main
```

The reviewer opens in a split beside the agent: changed files as a tree on the
left, and the selected file as a unified diff on the right. GitHub review
threads show in the line numbers, and the bar above the diff shows whether the
agent is working, idle or waiting on you.

The reviewer keeps up on its own: it reloads when the agent edits files, and
fetches the pull request's threads each minute, so new reviews come in and
threads that someone, or a bot such as embark-bot, resolved leave.

| Key | Does |
| --- | --- |
| `<CR>` | open the file under the cursor in the tree |
| `]f` `[f` | next or previous file |
| `]c` `[c` | next or previous change |
| `]d` `[d` | next or previous comment |
| `K` | read the comments on this line; `K` again to scroll them |
| `c` | write a comment on this line, or on a visual range; `:w` saves it |
| `x` | delete your comment on this line |
| `s` | send the comments on this line to the agent; twice to resend |
| `S` | send all your unsent comments |
| `R` | reload the files and the GitHub threads now |
| `q` | quit |

`s` pastes the comments into the agent's prompt, such as:

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

Run `rexr` without `open` to review in the current terminal, without an agent.

## Notes

- Your comments, and which threads are in the agent's chat, are saved per
  branch in `.git/rexr/`. rexr never posts to GitHub.
- The diff follows your `'diffopt'`: algorithm, `indent-heuristic`,
  `linematch`, whitespace options and `inline:` for changed words.
- Highlighting uses the treesitter parsers you installed under
  `stdpath("data")/site`, with regex syntax for the rest.
- Comments follow their code as the agent edits it. A comment whose code is
  gone, appears more than once, or is too short to recognise, such as a lone
  `}`, stays put and is marked "changed locally".

## Test

```sh
for t in test/*_test.lua; do nvim --clean --headless -l "$t" || break; done
```

- `inline_test.lua`: rexr marks the same changed words as Neovim's own diff
  mode.
- `map_left_test.lua`: comments on removed lines land where the removal is
  drawn, over hand-made and random edits.
- `comments_test.lua`: comments follow their code as it moves, and never jump
  to code that only looks the same.

[Rex]: https://www.superlogical.com/rex/docs
[GitHub CLI]: https://cli.github.com
