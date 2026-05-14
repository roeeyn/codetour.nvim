# codetour.nvim

> An ordered, annotated trail through a codebase. A guided tour you can replay forward and backward with `:cnext` / `:cprev`, with named tours per repo, virtual-text notes that follow the code, and per-tour JSON files at `<repo>/.codetour/`.

## Why

Existing Neovim plugins solve "remember a few important files" — harpoon, arrow, the bookmarks family. They're great for **task switching**: jump back to file X right now.

codetour.nvim fills a different gap: **codebase exploration**. The cognitive task of building a mental map of how a system fits together is *sequential* — first this entry, then this dispatch, then this handler. That's a path, not a set. Each stop deserves a note explaining *why this stop matters*.

The closest sibling is VS Code's [CodeTour](https://github.com/microsoft/codetour) by Microsoft. This is the Neovim version of that idea, with native quickfix navigation, per-tour storage, and live virtual-text annotations.

## Features

- **Ordered sequence of stops** traversed with the quickfix list (`:cnext` / `:cprev`)
- **A free-text note per stop** rendered as a virtual line *above* the line, with a configurable scannable prefix (e.g. `default (2/5): the dispatch handler`)
- **Multiple named tours per repo** — `:CodeTour create auth-flow`, `:CodeTour create billing-flow`, switch between them
- **Per-tour persistence** in `<repo>/.codetour/<name>.json` (visible at repo root, easy to commit and share — set `storage_path = ".git/info/codetour"` for hidden, per-clone tours)
- **Stable stop identity** — each stop carries a per-tour monotonic id, so removing one stop never invalidates the others' tracking or visual indices
- **Stops follow code edits** via extmarks, with cold-load re-anchoring via context-string match. Files that haven't been opened yet get an offline drift scan from disk before they show up in the quickfix list, so `:CodeTour open` lands on the right line even across external edits
- **Saves and restores your prior quickfix list** across `:CodeTour open` / `:CodeTour close`
- **Cross-buffer total updates** — adding a stop in one file refreshes the `(idx/total)` prefix in every other file
- **Telescope-friendly** picker via `vim.ui.select` (works with `telescope-ui-select.nvim`, `dressing.nvim`, etc.)

## Requirements

- Neovim 0.10 or later (uses extmark-based signs)
- `git` on `$PATH`

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "roeeyn/codetour.nvim",
  config = function()
    require("codetour").setup({})
  end,
}
```

## Quick start

```vim
:e some-file.lua
" cursor on the entry-point line
:CodeTour add entry point     " auto-creates a "default" tour on first add

:e other-file.lua
" cursor on the dispatch handler
:CodeTour add dispatch handler

:CodeTour open    " populate quickfix, jump to stop 1
:cnext            " walk to stop 2
:CodeTour close   " restore your prior quickfix list
```

Quit Neovim and reopen — the tour is still there.

## Commands

Every codetour action is a subcommand of `:CodeTour`. Type `:CodeTour ` and press `<Tab>` to discover them; `:CodeTour select <Tab>` and `:CodeTour delete <Tab>` complete tour names.

| Command | Description |
|---|---|
| `:CodeTour` | Open the plugin's primary UI: an editable list of all stops with a syntax-highlighted preview. Jump with `<CR>`, reorder by moving lines, edit notes inline, remove by deleting lines. `:w` to apply atomically. |
| **Tour management** | |
| `:CodeTour create <name>` | Create a new empty tour and make it active |
| `:CodeTour select [name]` | Switch the active tour (no arg → opens a picker) |
| `:CodeTour delete [name]` | Delete a tour (with confirm) |
| `:CodeTour rename <new-name>` | Rename the currently-active tour. Errors if the new name collides or contains `/ \ :`. |
| **Stops** | |
| `:CodeTour add [note...]` | Add a stop at the cursor with optional inline note |
| `:CodeTour remove` | Remove the stop nearest the cursor in the current buffer |
| `:CodeTour note <text>` | Replace the nearest stop's note with the given text |
| **Navigation** | |
| `:CodeTour open` | Populate the quickfix list with the active tour, jump to stop 1 |
| `:CodeTour close` | Restore the quickfix list that was active before `:CodeTour open` |
| `:CodeTour list` | Open a picker over the active tour's stops; `<CR>` jumps |
| `:CodeTour next-stop` | Jump cursor to the next stop in the **current buffer** (by line). Pure cursor movement; no qf side effects |
| `:CodeTour prev-stop` | Jump cursor to the previous stop in the current buffer |
| **Display & debug** | |
| `:CodeTour toggle-notes` | Hide / show all virtual-text notes |
| `:CodeTour dump` | Print the in-memory state to `:messages` (debug aid) |

## Configuration

```lua
require("codetour").setup({
  -- :CodeTour close runs :cclose. Default leaves the qf window state alone.
  close_qf_on_tour_close = false,

  -- Highlight group that CodetourNote links to. Override with any group name,
  -- or set your own `:hi CodetourNote ...` to bypass the link entirely.
  note_highlight = "DiagnosticInfo",

  -- Template prefixed to each rendered note. Placeholders: {name}, {idx}, {total}.
  -- Set to "" to disable. Unknown placeholders pass through untouched.
  note_prefix = "{name} ({idx}/{total}): ",

  -- Register `<leader>t*` keymaps automatically (default: false).
  default_keymaps = false,

  -- Show informational notifications ("stop added", "tour created", etc.).
  -- Warnings and errors are always shown. Default false (quiet mode).
  debug = false,

  -- Where tour files live. Relative paths join to the git root; absolute
  -- paths are used as-is. Default ".codetour" (visible at repo root,
  -- easily committed and shared with teammates).
  --
  -- Common alternatives:
  --   storage_path = ".git/info/codetour"  -- hidden, never committed
  --   storage_path = "~/.local/share/codetour/myproject"  -- outside repo
  storage_path = ".codetour",

  -- Sign-column markers at each stop's line. Each sign shows a 1-cell
  -- prefix glyph followed by the stop's index (e.g. "󰈻1", "󰈻2", ...).
  -- Sign-column is hard-capped at 2 cells, so the prefix only renders for
  -- single-digit indices (1-9); 10+ falls back to the bare number.
  signs = {
    enabled = true,
    text = nil,           -- nil = use the prefix+index logic below; set to a fixed string ("●") to override
    prefix = "󰈻",         -- nf-md-flag (Nerd Font). Use "▸" if you don't have a Nerd Font, or "" to disable.
    highlight = "Special",
  },
})
```

### Default keymaps (when `default_keymaps = true`)

| Key | Action |
|---|---|
| `<leader>ta` | `:CodeTour add` (no note) |
| `<leader>te` | edit nearest note (prompt) |
| `<leader>tx` | `:CodeTour remove` |
| `<leader>tn` | `:cnext` |
| `<leader>tp` | `:cprev` |
| `<leader>to` | `:CodeTour open` |
| `<leader>tc` | `:CodeTour close` |
| `<leader>tl` | `:CodeTour list` (stop picker) |
| `<leader>ts` | `:CodeTour select` (tour picker) |
| `<leader>tv` | toggle virtual-text notes |

### Telescope-rendered pickers

`:CodeTour list` and `:CodeTour select` use `vim.ui.select`. To render them in Telescope, install [`telescope-ui-select.nvim`](https://github.com/nvim-telescope/telescope-ui-select.nvim):

```lua
{
  "nvim-telescope/telescope-ui-select.nvim",
  config = function()
    require("telescope").load_extension("ui-select")
  end,
}
```

`dressing.nvim` and `noice.nvim` both work too. A native Telescope extension with split-pane preview is on the TODOs.

## Agent skills

The plugin ships an agent skill that teaches Claude (and other agent runtimes) how to author tours on demand — so you can prompt *"show me the auth flow in this API"* in any project and get back a curated `.codetour/auth-flow.json`.

| Skill | What it does |
|---|---|
| `create-codetour-tour` | Authors or amends tour files (the JSON at `<repo>/.codetour/<name>.json`). Knows the schema, path conventions, the why-not-what note style, and the 3–7-stop sweet spot. Triggers on prompts like *"show me the X flow"*, *"trace how Y works"*, *"add a stop to the auth-flow tour"*. |

### Install (recommended — auto-updates with `npm` cache)

[`skills`](https://github.com/vercel-labs/skills) is a small CLI that installs agent skills from a GitHub repo. It auto-discovers `.claude/skills/<skill-name>/` and installs to `~/.claude/skills/`:

```sh
npx skills@latest add roeeyn/codetour.nvim
```

Pick `create-codetour-tour` when prompted (or pass `-g` to install globally without the prompt). Re-run the same command later to update.

### Install (manual, if you don't want `npx`)

If you use `lazy.nvim` and want the skill to track this repo:

```sh
ln -s ~/.local/share/nvim/lazy/codetour.nvim/.claude/skills/create-codetour-tour ~/.claude/skills/create-codetour-tour
```

Or copy if you'd rather snapshot the current version:

```sh
cp -r ~/.local/share/nvim/lazy/codetour.nvim/.claude/skills/create-codetour-tour ~/.claude/skills/
```

The symlink version updates whenever you `git pull` (or your plugin manager updates the plugin). The copy version doesn't — you'll need to re-run to get schema changes.

### Verify it loaded

In any project, ask Claude: *"create a tour of how requests get authenticated in this codebase."* If the skill is installed, Claude consults it and produces a `.codetour/<name>.json` file. If not, it'll just answer in prose.

## How it works

**Storage layout.** Each tour is its own JSON file at `<repo>/.codetour/<name>.json` (configurable via `storage_path`). A small `_active_tour.txt` pointer remembers the last-active tour across sessions. The default location is visible at repo root so tours are easy to commit, share with teammates, and read from external tools (e.g. a future CLI). Per-tour files mean atomic per-tour writes, easy export (`cp auth.json /tmp/share`), and no concurrent-write hazard across worktrees.

If you'd rather keep tours private to your clone, set `storage_path = ".git/info/codetour"` — the legacy hidden location, auto-gitignored by every git client.

**Stop file paths.** Stored relative to the git root, so a fresh clone in a different directory still resolves them correctly. Stops in files outside the git root keep their absolute paths.

**Live position tracking.** Stops are anchored via extmarks during a session, so inserting or deleting lines above a stop shifts it correctly. Quickfix navigation reads the live position before jumping.

**Cold-load re-anchoring.** Each stop also persists a 60-char context snippet of its line. When the file is opened in nvim, the plugin searches ±20 lines around the stored position for the snippet and re-anchors there if it moved, notifying you that the stop drifted. For stops whose files aren't open yet, the same scan runs against the file content on disk when the tour becomes active — so `:CodeTour open` populates the quickfix with the correct current line, not the stale persisted one.

**Multi-tour.** Each `:CodeTour create <name>` makes a new file. `:CodeTour select <name>` switches active. The active tour is what `:CodeTour add`, `:CodeTour open`, `:CodeTour list`, etc. operate on.

**`:CodeTour` (oil-style buffer).** Opens a 25/75 vsplit: editable list on the left, syntax-highlighted preview on the right that follows the cursor. Each line in the list looks like:

```
[1]  lua/foo.lua:10  ─  entry point
[2]  lua/foo.lua:25  ─  dispatch handler
[3]  lua/bar.lua:5   ─  side effect
```

The `[N]` is the stop's identifier. Reorder by moving lines, edit the text after `─` to change a note, delete a line to drop the stop. `:w` parses the buffer and applies all changes atomically — if any line is malformed, the entire save is rejected with an error and state is left untouched. `<CR>` on a stop jumps to it (refuses if there are unsaved edits). `q` closes without saving. `:x` saves and closes.

Editing `file:lnum` is ignored — those segments are display-only. Use `:CodeTour add` to add new stops; `:CodeTour` is for managing existing ones.

## Status

Active development:

- ✅ Plugin scaffold, in-memory stops, quickfix integration
- ✅ Per-tour JSON persistence at `<repo>/.codetour/<name>.json`
- ✅ Extmark-based anchoring + context-string re-anchor (online and offline drift)
- ✅ `virt_lines` notes with configurable prefix and highlight
- ✅ Stop dedupe, overwrite confirms, qf cursor preservation
- ✅ Multi-tour support (replaced the original branch-awareness)
- ✅ `:CodeTour list` / `:CodeTour select` pickers via `vim.ui.select`
- ✅ `:CodeTour` oil-style editable UI (jump, reorder, edit notes inline, delete; atomic `:w` apply)
- ✅ Stable per-tour stop ids so remove/replace doesn't shift identities
- ✅ Default keymaps, edge case audit

See **TODOS** below for what's next.

## Development

```sh
make test    # run plenary specs (~140)
make fmt     # format with stylua
make check   # stylua --check (used by CI)
```

Focus a single test or block with `it.only(...)` / `describe.only(...)` — plenary picks those up.

### Pre-commit hooks

This repo uses the [`pre-commit` framework](https://pre-commit.com). Install it once (e.g. `brew install pre-commit` or `pip install pre-commit`), then:

```sh
pre-commit install              # one-shot per clone — installs the git hook
pre-commit run --all-files      # validate everything on demand
pre-commit autoupdate           # refresh hook versions periodically
```

The configured hooks (`.pre-commit-config.yaml`):

| Hook | What it does |
|---|---|
| `trailing-whitespace` | Strips trailing whitespace |
| `end-of-file-fixer` | Ensures final newline |
| `check-merge-conflict` | Catches stray `<<<<<<<` markers |
| `check-yaml` | Validates YAML files |
| `stylua-system` | `stylua --check` against staged `.lua` files |
| `plenary-tests` | Runs `make test` when any `.lua` file is staged |

Bypass with `git commit --no-verify` when you really need to.

## Inspirations

[harpoon.nvim](https://github.com/ThePrimeagen/harpoon), [arrow.nvim](https://github.com/otavioschwanck/arrow.nvim), [VS Code Bookmarks](https://github.com/alefragnani/vscode-bookmarks) by Alessandro Fragnani, [VS Code CodeTour](https://github.com/microsoft/codetour) by Microsoft.

## TODOS

- Native Telescope extension (`:Telescope codetour stops`) with split-pane
  preview and custom mappings (`<C-d>` delete, `<C-e>` edit-note inline).
  Until then, `:CodeTour list` and `:CodeTour select` use `vim.ui.select`, which
  upgrades transparently if the user installs
  [`telescope-ui-select.nvim`](https://github.com/nvim-telescope/telescope-ui-select.nvim).
- Lualine component showing the active tour name + stop count
  (e.g. `tour: auth-flow [2/5]`). Possibly skip — the qf cwindow already
  surfaces this when open.
- Create demo (video) of common usage
- Make sure that the tour add operations only apply if a tour is active
