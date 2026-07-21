# contuts

> **Context is the bottleneck, not code generation.**

> **License:** AGPL-3.0 — You can use, study, and share contuts freely. If you modify and distribute it, your changes must be shared under the same license.

> **⚠ PROTOTYPE** — Proof of concept, actively evolving. Expect rough edges.

---

## What this is

AI writes code and makes claims about your codebase faster than you can understand them. That gap — between what the AI says and what you personally know and trust — is where mistakes get accepted and understanding erodes.

contuts is a tool for **collapsing that gap as fast as possible.** It doesn't verify claims for you. It doesn't trust the AI for you. It gives you the context you need to agree or disagree, then gets out of your way.

**Plan → Build → Review → Decide**

---

## Why this exists

The current AI coding workflow is: generate → accept. You read a wall of text, trust the green diff, and move on. Over time, you understand your own codebase less. You're not collaborating — you're approving.

contuts was built on a different belief: **planning is interactive.** When the AI says something — *"there's a race condition on line 42"*, *"this function is missing validation"* — it should come with evidence you can navigate, not just prose you have to mentally map onto your code. Your job isn't to trust. Your job is to judge, and judgment requires context.

The faster you can build that context, the faster you can make real decisions. Not rubber-stamps, decisions.

---

## How it works

| Phase | Command | What happens |
|---|---|---|
| **Plan** | `:ContutsPrompt` | AI reads your codebase in a read-only worktree. It can answer questions, find bugs, and explain code — but cannot write a single byte. Every claim includes navigable evidence. |
| **Build** | `:ContutsBuild [msg]` | AI gets write access to the worktree. It implements changes, then commits them. |
| **Review** | `:ContutsReview` | Side-by-side vimdiff of every changed file. Navigate with Enter. See exactly what the AI did. |
| **Merge** | `:ContutsMerge` | Squash-merge the worktree branch into your current branch. |
| **Discard** | `:ContutsDiscard` | Delete the worktree and branch. |

---

## Contuts Review

A three-window layout showing exactly what the AI changed, compared against your branch HEAD (not `main` — only the AI's changes, not everything since main).

```
+----------------------+----------------------+
| Your branch (before) | Worktree (after)     |
| vimdiff              | vimdiff              |
| scrollbind           | scrollbind           |
+---------------------------------------------+
|  src/modules/ticket-solution/entity.ts      |
|  src/modules/ticket-solution/controller.ts  |
|  src/modules/ticket-solution/service.ts     |
|  <CR> = load file into diff above           |
+---------------------------------------------+
```

- `<CR>` on any file loads it into both diff windows
- The diff base is the exact commit where the worktree was forked

---

## Contuts Evidence

The core of the context-building idea. When the AI makes claims, each one is attached to a specific file and line with a severity — not buried in a paragraph.

```
+--------------------------------------+
|  File opened at claimed line         |
|  ⚑ line 42 — background highlighted  |
|  ⚐ line 88 — background highlighted  |
+--------------------------------------+
|  ⚑  src/ticket.service.ts:42 Race    |
|  ⚑  src/ticket.service.ts:88 Valid   |
|  ⚐  src/auth.service.ts:15 No auth   |
|  <CR> = open file   d = detail        |
+--------------------------------------+
```

- **`<CR>`** on a claim → opens the file at that line, highlights all claims for that file
- **`d`** on a claim → floating window with the full explanation
- **`<Leader>ce`** anywhere on a marked line → shows the claim detail
- **Colors by severity:** red (`⚑`), yellow (`⚐`), blue (`●`)
- Marks are ephemeral — they don't touch your files

Evidence doesn't prove or verify. It gives you a starting point — the fastest possible path from "I don't understand this claim" to "I have enough information to judge it."

### What evidence should become

The current system just colors AI claims. The next step is to weave in real tools — linters, type checkers, git blame, data flow graphs — not to prove the AI right or wrong, but to **collapse context faster.** You press a key, you see the relevant flow, the related functions, the last time this line changed. You still make the call. The tool just makes sure you have enough to make it well.

---

## Commands

| Command / Keymap | What it does |
|---|---|
| `:ContutsPrompt` | Open chat window (plan mode — read-only) |
| `:ContutsBuild [msg]` | Build mode — AI writes in isolated worktree |
| `:ContutsReview` | Side-by-side vimdiff of changed files |
| `:ContutsEvidence` | View AI claims as colored line marks |
| `:ContutsMerge` | Squash-merge worktree into current branch |
| `:ContutsDiscard` | Delete worktree and branch |
| `:ContutsRestart` | Restart the Node.js server |
| `<Leader>ce` | Show claim detail for the line under cursor |

---

## Architecture

```
Neovim                          Node.js server                  opencode
┌─────────────┐   TCP/JSON    ┌──────────────┐    spawn    ┌──────────┐
│ chat window  │◄────────────►│ handlePrompt │◄───────────►│   AI     │
│ review view  │              │ handleBuild  │              │  agent   │
│ evidence view│              │ handleMerge  │              └──────────┘
└─────────────┘              │ handleDiscard│                    ↕
                              └──────┬───────┘           Git worktree
                                     │                     (isolated)
                               ┌─────┴─────┐
                               │  git diff  │
                               └───────────┘
```

Plan mode: worktree is read-only. Build mode: writable, changes committed automatically. Worktree is forked from your current HEAD.

---

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

---

## The irony

This entire project was fully vibecoded by an AI agent talking to a human who kept saying *"no, make me review everything first"* — directly violating contuts' own mission of human-in-the-loop review.

The tool that maximizes human context was built by an agent, because the human refused to let the agent run unchecked.

Agent: *"go brrrrr"*
Human: *"not on my branch you don't"*
