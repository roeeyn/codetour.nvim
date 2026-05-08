# codetour.nvim

> An ordered, annotated trail through a codebase. A guided tour you can replay forward and backward with `:cnext` / `:cprev`, with named tours per repo, virtual-text notes that follow the code, and per-stop persistence in `.git/info/`.

## Why

Existing Neovim plugins solve "remember a few important files" — harpoon, arrow, the bookmarks family. They're great for **task switching**: jump back to file X right now.

codetour.nvim fills a different gap: **codebase exploration**. The cognitive task of building a mental map of how a system fits together is *sequential* — first this entry, then this dispatch, then this handler. That's a path, not a set. Each stop deserves a note explaining *why this stop matters*.

The closest sibling is VS Code's [CodeTour](https://github.com/microsoft/codetour) by Microsoft. This is the Neovim version of that idea, with native quickfix navigation, per-tour storage, and live virtual-text annotations.

## Features

- **Ordered sequence of stops** traversed with the quickfix list (`:cnext` / `:cprev`)
- **A free-text note per stop** rendered as a virtual line *above* the line, with a configurable scannable prefix (e.g. `default (2/5): the dispatch handler`)
- **Multiple named tours per repo** — `:TourCreate auth-flow`, `:TourCreate billing-flow`, switch between them
- **Per-tour persistence** in `<repo>/.git/info/codetour/<name>.json` (auto-gitignored, per-clone)
- **Stops follow code edits** via extmarks, with cold-load re-anchoring via context-string match if files changed while nvim was closed
- **Saves and restores your prior quickfix list** across `:TourOpen` / `:TourClose`
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
:TourAdd entry point         " auto-creates a "default" tour on first add

:e other-file.lua
" cursor on the dispatch handler
:TourAdd dispatch handler

:TourOpen        " populate quickfix, jump to stop 1
:cnext           " walk to stop 2
:TourClose       " restore your prior quickfix list
```

Quit Neovim and reopen — the tour is still there.

## Commands

| Command | Description |
|---|---|
| **Tour management** | |
| `:TourCreate <name>` | Create a new empty tour and make it active |
| `:TourSelect [name]` | Switch the active tour (no arg → opens a picker) |
| `:TourDelete [name]` | Delete a tour (with confirm) |
| **Stops** | |
| `:TourAdd [note...]` | Add a stop at the cursor with optional inline note |
| `:TourRemove` | Remove the stop nearest the cursor in the current buffer |
| `:TourNoteEdit <text>` | Replace the nearest stop's note with the given text |
| **Navigation** | |
| `:TourOpen` | Populate the quickfix list with the active tour, jump to stop 1 |
| `:TourClose` | Restore the quickfix list that was active before `:TourOpen` |
| `:TourList` | Open a picker over the active tour's stops; `<CR>` jumps |
| **Display** | |
| `:TourNotesVirtualTextToggle` | Hide / show all virtual-text notes |
| `:TourDump` | Print the in-memory state to `:messages` (debug aid) |

## Configuration

```lua
require("codetour").setup({
  -- :TourClose runs :cclose. Default leaves the qf window state alone.
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

  -- Sign-column markers at each stop's line. Each sign shows the stop's
  -- index (1, 2, ...) by default. Set `text` to a fixed string for a
  -- uniform marker like "●".
  signs = {
    enabled = true,
    text = nil,           -- nil = stop index; or e.g. "●", "▎", "⌖"
    highlight = "Special",
  },
})
```

### Default keymaps (when `default_keymaps = true`)

| Key | Action |
|---|---|
| `<leader>ta` | `:TourAdd` (no note) |
| `<leader>te` | edit nearest note (prompt) |
| `<leader>tx` | `:TourRemove` |
| `<leader>tn` | `:cnext` |
| `<leader>tp` | `:cprev` |
| `<leader>to` | `:TourOpen` |
| `<leader>tc` | `:TourClose` |
| `<leader>tl` | `:TourList` (stop picker) |
| `<leader>ts` | `:TourSelect` (tour picker) |
| `<leader>tv` | toggle virtual-text notes |

### Telescope-rendered pickers

`:TourList` and `:TourSelect` use `vim.ui.select`. To render them in Telescope, install [`telescope-ui-select.nvim`](https://github.com/nvim-telescope/telescope-ui-select.nvim):

```lua
{
  "nvim-telescope/telescope-ui-select.nvim",
  config = function()
    require("telescope").load_extension("ui-select")
  end,
}
```

`dressing.nvim` and `noice.nvim` both work too. A native Telescope extension with split-pane preview is on the TODOs.

## How it works

**Storage layout.** Each tour is its own JSON file at `<repo>/.codetour/<name>.json` (configurable via `storage_path`). A small `_active_tour.txt` pointer remembers the last-active tour across sessions. The default location is visible at repo root so tours are easy to commit, share with teammates, and read from external tools (e.g. a future CLI). Per-tour files mean atomic per-tour writes, easy export (`cp auth.json /tmp/share`), and no concurrent-write hazard across worktrees.

If you'd rather keep tours private to your clone, set `storage_path = ".git/info/codetour"` — the legacy hidden location, auto-gitignored by every git client.

**Stop file paths.** Stored relative to the git root, so a fresh clone in a different directory still resolves them correctly. Stops in files outside the git root keep their absolute paths.

**Live position tracking.** Stops are anchored via extmarks during a session, so inserting or deleting lines above a stop shifts it correctly. Quickfix navigation reads the live position before jumping.

**Cold-load re-anchoring.** Each stop also persists a 60-char context snippet of its line. On reopen, if a file changed while nvim was closed, the plugin searches ±20 lines for the snippet and re-anchors there, notifying you that the stop drifted.

**Multi-tour.** Each `:TourCreate <name>` makes a new file. `:TourSelect <name>` switches active. The active tour is what `:TourAdd`, `:TourOpen`, `:TourList`, etc. operate on.

## Status

Active development through Phases 0–10:

- ✅ Plugin scaffold, in-memory stops, quickfix integration
- ✅ Per-tour JSON persistence in `.git/info/codetour/`
- ✅ Extmark-based anchoring + context-string re-anchor
- ✅ `virt_lines` notes with configurable prefix and highlight
- ✅ Stop dedupe, overwrite confirms, qf cursor preservation
- ✅ Multi-tour support (replaced the original branch-awareness)
- ✅ `:TourList` / `:TourSelect` pickers via `vim.ui.select`
- ✅ Default keymaps, edge case audit

See **TODOS** below for what's next.

## Development

```sh
make test    # run plenary specs (~70)
make fmt     # format with stylua
make check   # stylua --check (used by CI)
```

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

- add precommit validations
- For all the prints, evaluate if they need to be enabled by a debug config, or if they are strictly relevant
    - add a debug config
- configurable storage path (alternative to `.git/info/`)
- gitgutter-style sign-column markers for stop lines (like arrow.nvim)
- keyboard shortcut to jump between stops in the same file (like git hunks)
- edit-in-buffer like oil for bulk edit / reorder / remove
- native Telescope extension (`:Telescope codetour stops`) with split-pane
    - preview and custom mappings (`<C-d>` delete, `<C-e>` edit-note inline)
- lualine integration showing active tour name + stop count
    - we may skip this as we may rely on the qf UI
