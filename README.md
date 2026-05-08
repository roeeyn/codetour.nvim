# codetour.nvim

> An ordered, annotated trail through a codebase. A guided tour you can replay forward and backward with `:cnext` / `:cprev`.

## Why

Existing Neovim plugins solve "remember a few important files" — harpoon, arrow, the bookmarks family. They're great for **task switching**: jump back to file X right now.

codetour.nvim fills a different gap: **codebase exploration**. The cognitive task of building a mental map of how a system fits together is *sequential* — first this entry, then this dispatch, then this handler. That's a path, not a set. Each stop deserves a note explaining *why this stop matters*.

The closest sibling is VS Code's [CodeTour](https://github.com/microsoft/codetour) by Microsoft. This is the Neovim version of that idea, with native quickfix navigation and per-branch git-tracked persistence.

## Features

- Ordered sequence of stops, traversed with the quickfix list
- A free-text note per stop
- Per-branch persistence in `.git/info/codetour/<branch>.json` (auto-gitignored, per-clone)
- Saves and restores your prior quickfix list across `:TourOpen` / `:TourClose`

## Requirements

- Neovim 0.9 or later
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
:TourAdd entry point

:e other-file.lua
" cursor on the dispatch handler
:TourAdd dispatch handler

:TourOpen        " populate quickfix, jump to stop 1
:cnext           " walk to stop 2
:TourClose       " restore your prior quickfix list
```

Quit Neovim and reopen — the path is still there.

## Commands

| Command | Description |
|---|---|
| `:TourStart [name]` | Begin a new path on the current branch (clears any existing one) |
| `:TourAdd [note...]` | Add the cursor's line as a stop with optional note |
| `:TourOpen` | Populate the quickfix list with the current path, jump to stop 1 |
| `:TourClose` | Restore the quickfix list that was active before `:TourOpen` |
| `:TourDump` | Print the in-memory state to `:messages` (debug aid) |

## Configuration

```lua
require("codetour").setup({
  -- If true, :TourClose runs :cclose. Default leaves the qf window state alone.
  close_qf_on_tour_close = false,
})
```

## How it works

State for each branch lives in `<repo>/.git/info/codetour/<branch>.json`. `.git/info/` is auto-ignored by every git client, so the file is invisible to `git status` and never committed. Branch names with `/` are written with `_` in the filename.

Stop file paths are stored relative to the git root, so a fresh clone in a different directory still resolves them correctly. Stops in files outside the git root keep their absolute paths.

Branch switches mid-session do not yet auto-reload — restart Neovim to pick up a different branch's path. (Auto-load on `BufEnter` is on the roadmap.)

## Status

Active development. Implemented through Phase 3: scaffold, in-memory stops, quickfix integration, JSON persistence.

Coming: extmark anchoring (stops follow inserted/deleted lines), context-string re-anchor on cold load, `virt_lines` notes above each stop, `:TourEdit`, `:TourRemove`, branch-aware auto-load on `BufEnter`, `:TourList` Telescope picker.

## Development

```sh
make test    # run plenary specs
make fmt     # format with stylua
make check   # stylua --check (used by CI)
```

## Inspirations

[harpoon.nvim](https://github.com/ThePrimeagen/harpoon), [arrow.nvim](https://github.com/otavioschwanck/arrow.nvim), [VS Code Bookmarks](https://github.com/alefragnani/vscode-bookmarks) by Alessandro Fragnani, [VS Code CodeTour](https://github.com/microsoft/codetour) by Microsoft.
