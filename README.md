# contuts

> **Human-in-the-loop AI code review for people who trust humans more than agents.**

> **License:** AGPL-3.0 — You can use, study, and share contuts freely. If you modify and distribute it, your changes must be shared under the same license. The code is not yours to close off.

> **⚠ PROTOTYPE** — Proof of concept, actively evolving. Expect rough edges.

---

## Mission

AI generates code at an incredible pace. The bottleneck is no longer writing code — it's **understanding, verifying, and deciding** what to accept.

contuts flips the default: AI works in isolated git worktrees, never touching your real branch. Every change must be explicitly reviewed before it merges. Every claim the AI makes about your code should be navigable, verifiable, and interactive.

**Plan → Build → Review → Merge**

No auto-merge. No blind trust. You see everything before it lands.

---

## How It Works

contuts wraps [opencode](https://opencode.ai) with a structured four-phase workflow:

| Phase | Command | What happens |
|---|---|---|
| **Plan** | `:ContutsPrompt` | AI reads your codebase in a read-only worktree. It can answer questions, find bugs, and explain code — but cannot write a single byte. |
| **Build** | `:ContutsBuild [msg]` | AI gets write access to the worktree. It implements changes, then commits them. You get a summary of files changed and lines added/removed. |
| **Review** | `:ContutsReview` | Side-by-side vimdiff of every changed file. Navigate through the file list, press Enter to load any file into the diff. See exactly what the AI did. |
| **Merge** | `:ContutsMerge` | Squash-merge the worktree branch into your current branch. Only after you've reviewed everything. |
| **Discard** | `:ContutsDiscard` | Delete the worktree and branch. Walk away clean. |

---

## Contuts Review (in detail)

The review is the heart of contuts. When you run `:ContutsReview`:

1. A new tab opens with three windows:
   - **Top-left:** The file from your current branch (before AI changes)
   - **Top-right:** The same file from the worktree branch (after AI changes)
   - **Bottom:** A navigable file list of every changed file (full width)

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

2. Move through the list with `j`/`k`, press **Enter** on any file.
3. Both sides reload with the new file and diff highlights update.
4. The diff base is the exact commit where the worktree was created (your branch HEAD at the time), not `main`. You see **only what the AI changed**, not everything since `main`.

---

## Evidence Viewer

When the AI makes claims during planning — *"there's a race condition on line 42"*, *"this function lacks validation"* — `:ContutsEvidence` turns those claims into colored marks on your code.

```
+--------------------------------------+
|  File opened at claimed line         |
|  ⚑ line 42 — full line highlighted    |
|  ⚑ line 88 — full line highlighted    |
+--------------------------------------+
|  ⚑  src/ticket.service.ts:42 Race    |
|  ⚑  src/ticket.service.ts:88 Valid   |
|  ⚐  src/auth.service.ts:15 No auth   |
|  <CR> = open file    d = detail       |
+--------------------------------------+
```

- `⚑` **red** — error severity (full line background `#5c1a1a`)
- `⚐` **yellow** — warning severity (full line background `#5c5a1a`)
- `●` **blue** — info severity (full line background `#1a3c5c`)
- **`d`** on any claim → floating window with full explanation
- **`<Leader>ce`** anywhere on a marked line → shows the claim detail
- Marks are **ephemeral** — they don't touch your files, only the display

### Planned: Respond to Claims

Each claim will become interactive — you can disagree, ask for clarification, or confirm. Your responses are batched into a single follow-up prompt to the AI. No mini-chats, just structured human feedback appended to the same conversation.

The current evidence format uses a `<evidence>JSON</evidence>` tag embedded in the AI's response. The long-term plan is a formal JSON message protocol over TCP with typed schemas.

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
                               │  --stat    │
                               │  --numstat │
                               └───────────┘
```

- The worktree lives at `../contuts-<id>/` — never touches your real working tree.
- Plan mode: worktree is **read-only** (`chmod a-w`).
- Build mode: worktree is **writable**, changes are `git commit`ed automatically.
- Worktree is forked from your current branch HEAD, not from `main`. Diffs are accurate.

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

## The Irony

This entire project was fully vibecoded by an AI agent talking to a human who kept saying *"no, make me review everything first"* — directly violating contuts' own mission of human-in-the-loop review.

The tool that maximizes human decision-making was built by an agent, because the human refused to let the agent run unchecked.

Agent: *"go brrrrr"*
Human: *"not on my branch you don't"*
