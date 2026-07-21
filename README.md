# contuts — Human-centric AI code agent

> **⚠ PROTOTYPE / PROOF OF CONCEPT** — This is an experimental project exploring interactive AI-assisted code review. Expect rough edges and breaking changes. The protocol and architecture are actively evolving toward a formal specification.

**Currently Neovim-only. More editors coming soon.**

An editor-agnostic engine for human-controlled AI software development. Agents implement code, static analysis verifies reality, and interactive context magnifies the developer's understanding before changes are accepted.

# Every AI answer should become interactive.

AI provides hypotheses, explanations, and intent.
The engine turns those into navigable, verifiable engineering knowledge through static analysis, Git history, and runtime information.

**Plan → Build → Review → Merge**

A Neovim plugin that wraps opencode with a human-in-the-loop workflow. AI works in isolated git worktrees with explicit read-only (plan) and writable (build) modes. Every change is reviewed before it touches your main branch.

## Commands

| Command | What it does |
|---|---|
| `:ContutsPrompt` | Open chat window. **Plan mode** — agent can read your code, cannot write. |
| `:ContutsBuild [msg]` | **Build mode** — agent writes in an isolated worktree, commits changes. |
| `:ContutsReview` | Side-by-side vimdiff comparing `base` vs `branch`. Navigate files with `<CR>`. |
| `:ContutsEvidence` | View AI claims as colored line marks. `<CR>` opens file, `d` shows detail. |
| `:ContutsMerge` | Squash-merge the worktree branch into your main branch. |
| `:ContutsDiscard` | Delete the worktree and branch. Clean slate. |
| `:ContutsRestart` | Restart the server. |
| `<Leader>ce` | **Global keymap** — on a line with a claim mark, shows the full claim detail. |

## Evidence Viewer

When the AI makes claims about specific code locations (e.g. *"there's a race condition on line 42"*), the evidence viewer lets you examine them visually.

**How it works:**
1. Every plan prompt includes a system instruction asking the AI to format code claims as `<evidence>JSON</evidence>`.
2. The server strips the evidence block and sends it alongside the chat response.
3. `:ContutsEvidence` opens a tab with the file on top and evidence list on bottom.
4. Each claim gets a colored mark on the line (sign column + full line background):
   - `⚑` **red** — error severity
   - `⚐` **yellow** — warning severity
   - `●` **blue** — info severity
5. `<CR>` on a list entry opens the file at that line with all claims for that file highlighted.
6. `d` on a list entry shows the full claim detail in a floating window.
7. `<Leader>ce` anywhere on a line with a claim mark opens the detail float.

## Architecture

```
Neovim (chat window) ←TCP/JSON-lines→ Node.js server ←spawn→ opencode
                                            ↕
                                    Git worktree (isolated)
```

All AI work happens in `../contuts-<id>/` — never touches your real working tree until you `:ContutsMerge`.

## Protocol — Future Direction

The current evidence schema is a prototype embedded as a system prompt instruction. The long-term goal is a formal protocol:

```json
{
  "type": "evidence",
  "items": [
    {
      "file": "src/main.ts",
      "line": 42,
      "claim": "Unhandled promise rejection",
      "detail": "The async function lacks a .catch() handler.",
      "severity": "error"
    }
  ]
}
```

### Planned: Interactive Evidence Response

Each claim becomes interactive — you can respond to it with feedback (disagree, need more info, etc.), and all responses are batched into a single follow-up prompt to the AI. No mini-chats, just structured human feedback appended to the same conversation.

This will move from a textual `<evidence>` tag in the prompt to a dedicated JSON message type over the TCP protocol, with formal schemas and validation.

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
