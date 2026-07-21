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
| **Plan** | `:ContutsPrompt` | AI reads your codebase in a read-only worktree. Answers questions, finds bugs, explains code — but cannot write a single byte. Every claim includes navigable evidence. |
| **ContutsPlan** | `:ContutsPlan` | Interactive plan+build mode. Browse claims, annotate, add evidence, build individual pieces, explore code context. The AI refines its understanding as you go. Not a giant diff — piece by piece, claim by claim. |
| **Build** | `:ContutsBuild [msg]` | AI gets write access to the worktree. Implements everything at once and commits. |
| **Review** | `:ContutsReview` | Side-by-side vimdiff of every changed file. |
| **Merge** | `:ContutsMerge` | Squash-merge the worktree branch into your current branch. |
| **Discard** | `:ContutsDiscard` | Delete the worktree and branch. |

---

## ContutsPlan — interactive plan + build

This is where the real interaction happens. Not a chat, not a giant diff — a view where you and the AI work through the codebase together.

### Current state

A split view with evidence claims in a list and the referenced file open:

```
+--------------------------------------+
|  File opened at claimed line         |
|  ⚑ line 42 — background highlighted  |
+--------------------------------------+
|  [···] ⚑  src/ticket.service.ts:42   |
|  [P]    ⚐  src/ticket.service.ts:88  |
|  [✓]    ⚑  src/auth.service.ts:15    |
|  [✗]    ⚐  src/utils.ts:5            |
|  b=build  y=accept  n=reject         |
|  v=view diff  a=annotate  d=dismiss  |
+--------------------------------------+
```

| Key | What it does |
|---|---|
| `b` | Build this one claim — AI writes code in the worktree for just this item |
| `B` | Build all active claims at once (bulk mode) |
| `y` | Accept a proposal — commits the AI's change to the worktree |
| `n` | Reject a proposal — rolls back the AI's change completely |
| `v` | View the diff of a proposed change (or claim detail before build) |
| `a` | Annotate the current line with a human note or correction |
| `d` | Dismiss an AI claim — hides it from future builds |

### Where it's going

ContutsPlan is being rebuilt from scratch to be the **main interaction point** — merging plan and build into one fluid session:

1. **Initial prompt** — You describe the problem (or a future capture layer records reality for you). The AI responds with evidence claims pinned to specific lines.

2. **Iterative refinement** — You browse claims, annotate corrections, add your own evidence ("this function also matters"), and dismiss noise. The AI can rebuild its evidence model as you go — seeing what you agreed with, what you corrected, and what you added.

3. **Piece-by-piece building** — You don't accept a wall of changes. You build one claim at a time, review the diff, accept or reject. Each accepted piece is committed to the shared worktree. Each rejected piece is rolled back cleanly.

4. **Code context** — When a claim references a function or class, you can ask the tool to show what actually connects to it: callers, callees, entry points, related files. This is **tool-driven** (LSP references, import graphs, git history) — not the AI guessing. It shows what's true about the code, separate from what anyone thinks about it.

5. **Intention vs context** — These are two different things that live side by side:

   - **Context** is objective. These functions call this function. This type is used here. This file was changed in these commits. Tool-driven, verifiable.
   
   - **Intention** is what you and the AI believe should happen. Claims, annotations, dismissed items, accepted proposals. The plan. Evolving, subjective.

   contuts keeps both visible. The tool shows you the code truth. The evidence system tracks the human+AI intent. You need both to make good decisions.

6. **AI can re-query** — As you annotate and dismiss, the AI can revise its evidence. A dismissed claim might lead it to find a better one. An annotation might make it realize the scope is different. The evidence list evolves with your understanding.

The goal is to collapse the feedback loop. Not "AI writes everything → you review a giant diff" — but "AI proposes → you judge → AI adjusts → you approve → next piece." Each cycle is seconds, not minutes.

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

Claims are attached to a specific file and line with a severity — not buried in a paragraph.

```
+--------------------------------------+
|  File opened at claimed line         |
|  ⚑ line 42 — background highlighted  |
|  ⚐ line 88 — background highlighted  |
+--------------------------------------+
|  ⚑  src/ticket.service.ts:42 Race    |
|  ⚑  src/ticket.service.ts:88 Valid   |
|  ⚐  src/auth.service.ts:15 No auth   |
|  <CR> = open file   v = detail        |
+--------------------------------------+
```

- `<CR>` on a claim — opens the file at that line, highlights all claims for that file
- `v` on a claim — floating window with the full explanation
- `a` — annotate the line with your own note
- `d` — dismiss a claim as noise
- `<Leader>ce` anywhere on a marked line — shows the claim detail
- Colors by severity: red (`⚑`), yellow (`⚐`), blue (`●`)
- Marks are ephemeral — they don't touch your files

Evidence doesn't prove or verify. It gives you a starting point — the fastest possible path from "I don't understand this claim" to "I have enough information to judge it."

---

## Commands

| Command / Keymap | What it does |
|---|---|
| `:ContutsPrompt` | Open chat window (plan mode — read-only) |
| `:ContutsPlan` | Interactive plan+build — browse evidence, annotate, build piece-by-piece |
| `:ContutsBuild [msg]` | Bulk build — AI writes everything at once in isolated worktree |
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
│ plan view    │              │ handleBuild  │              │  agent   │
│ review view  │              │ planBuild    │              └──────────┘
│ evidence view│              │ planAccept   │                    ↕
└─────────────┘              │ planReject   │           Git worktree
                              │ handleMerge  │             (isolated)
                              │ handleDiscard│
                              └──────┬───────┘
                                     │
                               ┌─────┴─────┐
                               │  git diff  │
                               └───────────┘
```

Plan mode: worktree is read-only. Build mode: writable, changes committed automatically. Plan proposals: changes written but not committed until you accept. Worktree is forked from your current HEAD.

---

## Future direction: evidence from anywhere

Evidence today comes from one channel: the AI explains its reasoning
about your code, and you judge. But evidence can be stronger when it
doesn't start with a claim at all — when it starts with reality.

A future direction for contuts is an evidence acquisition layer that
captures **what actually happened** and feeds it directly into the
evidence model. The human never translates the problem into a prompt.
They observe a discrepancy, the capture layer records reality, and
contuts maps it to code.

No fixed shape — it adapts to where the problem lives:

| Source | What it captures |
|---|---|
| Frontend | Screenshots, DOM state, user flows, network payloads, expected vs actual |
| Backend | Debug-mode traces, request/response logs, database state, execution graphs |
| End-to-end | Full replay: user action → system layers → where reality deviated |

The AI reads the raw capture and builds evidence from it — claims
pinned to code, just like today. But the starting point is grounded in
observation, not generation.

The principle: **the best problem description is the problem itself,
not the human's attempt to explain it.** This isn't active development
today. It's a direction — a way to make evidence stronger and less
AI-reliant by anchoring it in real behavior.

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
