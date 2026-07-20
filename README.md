# contuts — Human-centric AI code agent for Neovim

**Plan → Build → Review → Merge**

A Neovim plugin that wraps opencode with a human-in-the-loop workflow. AI works in isolated git worktrees with explicit read-only (plan) and writable (build) modes. Every change is reviewed before it touches your main branch.

## Commands

| Command | What it does |
|---|---|
| `:ContutsPrompt` | Open chat window. **Plan mode** — agent can read your code, cannot write. |
| `:ContutsBuild [msg]` | **Build mode** — agent writes in an isolated worktree, commits changes. |
| `:ContutsReview` | Side-by-side vimdiff comparing `base` vs `branch`. Quickfix to pick any file. |
| `:ContutsMerge` | Squash-merge the worktree branch into your main branch. |
| `:ContutsDiscard` | Delete the worktree and branch. Clean slate. |
| `:ContutsRestart` | Restart the server. |

## Architecture

```
Neovim (chat window) ←TCP/JSON-lines→ Node.js server ←spawn→ opencode
                                            ↕
                                    Git worktree (isolated)
```

All AI work happens in `../contuts-<id>/` — never touches your real working tree until you `:ContutsMerge`.

## Requirements

- [Neovim](https://neovim.io/) 0.10+
- [opencode](https://opencode.ai) CLI installed and authenticated
- [Node.js](https://nodejs.org/) with `tsx` (comes with the project)

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  dir = '/path/to/contuts',
  dependencies = { 'tpope/vim-fugitive' },
  config = function()
    require('contuts')
  end
}
```

## The irony

This entire prototype was built by an AI agent talking to a human who kept asking "can you make it so I have to approve everything?".

The tool that maximizes human decision-making was itself built by an agent, because the human refused to let the agent run unchecked.

Agent: *"go brrrrr"*
Human: *"not on my branch you don't"*
