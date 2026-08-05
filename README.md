# contuts

> **Context is the bottleneck, not code generation.**

> **License:** AGPL-3.0 — You can use, study, and share contuts freely. If you modify and distribute it, your changes must be shared under the same license.

> **⚠ PROTOTYPE** — Proof of concept, actively evolving. Expect rough edges.

---

## What this is

A Neovim plugin that lets you chat with an AI about your code, capture observations (claims) and work items (tasks) pinned to files and lines, then build them one at a time — each change committed directly to your branch.

No worktree. No merge step. Just task-by-task iteration with the AI.

---

## Commands

| Command | What it does |
|---|---|
| `:ContutsChat` | Toggle a persistent chat window. Talk to the AI about your code. |
| `:ContutsAddClaim` | Visual select code, then add an observation (claim) pinned to that file and line. |
| `:ContutsAddTask` | Same, but adds a buildable work item (task). |
| `:ContutsPlan` | Open the plan view — a split tab with your code on top, claim/task list below. |
| `:ContutsDiff [git-diff-args]` | Step through a git diff — e.g. `:ContutsDiff HEAD~1` or `:ContutsDiff --cached`. Works on worktree changes, the index, any commit (`<rev>`), and stash entries (`stash@{0}`). Add `--lines` to walk every changed line as its own step instead of whole hunks. |
| `:ContutsDiffRestore` | Restore your working tree after a crash or interrupted session (reads the saved session from disk). |
| `:ContutsRestart` | Restart the Node.js server. |
| `<Leader>ce` | Show claim/task detail for the line under cursor. |

---

## Plan view keymaps

| Key | On a claim | On a task |
|---|---|---|
| `<CR>` | Open file at line | Open file at line |
| `v` | View detail | View detail, proposal diff, or intention |
| `d` | Dismiss | Dismiss |
| `c` | — | Open per-task mini-chat |
| `b` | — | Build this one task |
| `y` | — | Accept proposal |
| `n` | — | Reject proposal |
| `q` | Close plan view | |

### Workflow

1. **Chat** — `:ContutsChat`, talk about the code. Say "find evidence" or "generate tasks" to get structured claims/tasks back from the AI.
2. **Add your own** — Select code, `:ContutsAddClaim` or `:ContutsAddTask`, describe what needs doing.
3. **Plan** — `:ContutsPlan` shows everything in one list.
4. **Discuss** — `c` opens a mini-chat for a specific task. Refine the ask with the AI.
5. **Build** — `b` on a task. AI writes code, you see `[P]`. Press `v` to see the diff and the AI's intention.
6. **Accept / reject** — `y` commits to your branch. `n` rolls it back. The file on disk matches immediately.
7. **Next** — Pick another task, repeat.

### Diff review keymaps (`:ContutsDiff`)

You watch the **actual file** change — this is a patch walker, not a scratch-buffer diff view. When you open a diff, the working tree is rewound to the diff's base state, then every step applies one hunk with `git apply` directly to your real files. Neovim simply reloads the real buffer, so LSP, treesitter, and any plugin that reads files just work.

Each hunk is **previewed first**: the cursor jumps to the exact line where the hunk will insert or delete, so you see the before-state — the statusline shows `[preview]` with a `→ delete … / → add …` marker on the target line. Only pressing `j` applies it (and half-steps to the next hunk's preview). The walk is fully reversible (`git apply -R` per hunk). Pressing `q` restores your tree to its exact pre-walk state, including the index. Every session is backed up to disk (`/tmp/contuts/`), and `:ContutsDiffRestore` recovers your tree after a crash.

| Key | Action |
|---|---|
| `]` / `<CR>` / `n` | Apply previewed hunk, half-step to next preview |
| `[` / `p` | Undo previous hunk, half-step back to its preview |
| `J` / `K` | Jump to next / previous file |
| `g` / `G` | First hunk / apply everything (`[done]`) |
| `o` | Open the real file in a new tab at the previewed hunk |
| `q` | Restore the tree and close |

`j` / `k` are left untouched — you can roam the code freely between hunks, then press `]` to apply the previewed hunk. With `]` / `[` bound to step, `J` / `K` still jump between files.

By default each step is a whole hunk. Pass `--lines` (`:ContutsDiff --lines`) to step through the diff **one changed line at a time** — each add or delete is its own step, with the statusline naming the exact line (`→ add foo` / `→ delete bar`). Whole-file creates, binary and mode-only changes stay single steps.

What you can walk: unstaged worktree changes, staged changes (`--cached`), a commit diff (`HEAD`, `HEAD~1` …), or a stash (`stash@{0}`). Binaries are applied as single binary steps; mode-only changes are single steps too.

---

## Architecture

```
Neovim                      Node.js server                    opencode
┌──────────────┐  TCP/JSON  ┌────────────────┐   spawn    ┌──────────┐
│ chat window   │◄─────────►│ handlePrompt   │◄──────────►│   AI     │
│ plan view     │           │ planBuild      │              │  agent   │
│ mini-chats    │           │ planAccept     │              └──────────┘
└──────────────┘           │ planReject     │                    │
                            └────────────────┘              Direct commit
                                                             to your branch
```

No worktree. The AI writes directly to your working directory. Uncommitted work is stashed before each build and restored after. Every accepted build is committed to your current branch.

---

## How evidence generation works

The AI generates structured evidence when you ask it to. Keywords in chat — "evidence", "find issues", "generate tasks" — trigger system instructions that tell the AI to output a JSON array of claims or tasks wrapped in `<evidence>` tags. These are extracted and added to the plan view. Normal chat messages pass through without any evidence instruction.

---

## Future directions

- **Evidence capture layers** — feed runtime observations (backend traces, frontend screenshots, network logs) directly into the evidence model instead of starting from chat. The problem describes itself.
- **Task timeline / grouping** — express dependencies between tasks ("this should happen first, then this"). Build tasks in order, with each build's context including the results of previous tasks.

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

Agent: *"go brrrrr"*
Human: *"not on my branch you don't"*
