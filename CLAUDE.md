# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`codetour.nvim` — Neovim plugin for walking an ordered, annotated trail through a codebase via the quickfix list. Pure Lua, targets Neovim 0.10+, no runtime deps beyond `git`.

## Reference docs

- **`CONTEXT.md`** is the domain glossary — read it before touching code. It defines `Tour`, `Stop`, `Note`, `Active Tour`, `Anchor`, `Drift`, `Decoration`, `Tour Quickfix`. Comments and identifiers across the repo use those terms exactly; the architecture is hard to follow without them.
- **`README.md`** is the user-facing surface: commands (`:CodeTour <subcommand>`), configuration, smoke-test checklist.

## Commands

```sh
make test     # plenary.busted specs in tests/codetour_spec.lua (~143 specs)
make fmt      # stylua --write
make check    # stylua --check
```

Single-spec runs: change a target `it(...)` to `it.only(...)` (or `describe(...)` to `describe.only(...)`) — plenary supports `.only` for focused runs.

Running one spec file directly: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/codetour_spec.lua"`.

Pre-commit hooks gate every commit (trailing-whitespace, EOL, merge markers, stylua, `make test`). Install once: `pre-commit install`. Don't `--no-verify` without explicit instruction.

## Architecture

Three layers; do not blur them.

**Data layer (zero vim deps):**
- `lua/codetour/tour.lua` — `Tour` is **pure data**. No requires on vim, storage, log, or any sibling codetour module. Mutations return `(ok, err)` strings rather than calling `notify`. This is load-bearing — it's why ~25 unit tests run without spinning up a buffer or tempdir.
- `lua/codetour/storage.lua` — JSON read/write per tour. Owns the on-disk shape (`version`, `name`, `next_id`, paths relative to git root). Constructs and consumes `Tour` values.

**Orchestration:**
- `lua/codetour/state.lua` — single source of truth for the **active tour**. The only caller of `Tour` mutations and `decoration.*`. Translates `Tour`'s `(ok, err)` into `log.warn` for users, canonicalises stop file paths on `add`, runs offline drift detection on `ensure_loaded` / `select`.
- `lua/codetour/qf.lua` — builds and snapshots/restores the quickfix list. **`qf.open` defers `cfirst` + `cwindow` via `vim.schedule`** so heavy BufRead handlers (LSP attach, treesitter parse) don't freeze the GUI inside the user-command callback.

**Decoration (buffer-side rendering):**
- `lua/codetour/decoration.lua` — the **single seam** `state.lua` talks to. Thin facade. Requires its dependencies inside each function (not at module load) so tests that clear `package.loaded["codetour.notes"]` etc. don't leave decoration holding stale module references.
- `lua/codetour/anchor.lua` — extmark-based position tracking. Cold-load drift detection (`find_anchor_row` for loaded buffers, `detect_drift_offline` for files not yet open as buffers).
- `lua/codetour/notes.lua` — `virt_lines` rendering for stop notes.
- `lua/codetour/signs.lua` — sign-column markers.

**User-command surface:**
- `plugin/codetour.lua` — registers a single `:CodeTour <subcommand>` user command with completion. The `subcommands` table is the source of truth for what subcommands exist and how they complete (tour-name completion is opt-in via `complete = tour_names`). No-args opens the oil-style UI.
- `lua/codetour/init.lua` — public Lua API (`require("codetour").create()`, `.add()`, `.open_ui()`, ...). Kept stable so user keymaps and scripts have a surface independent of user-command names.
- `lua/codetour/edit.lua` — oil-style UI buffer. Pure functions (`render` / `parse` / `apply` / `commit`) are testable in isolation. Autocmd handlers (`_on_save`, `_on_enter`, `_update_preview`) are exposed on `M` with an underscore prefix so tests drive them directly instead of feedkeys-ing keystrokes.
- `lua/codetour/picker.lua` — `vim.ui.select` wrappers for `:CodeTour list` and `:CodeTour select`.

## Key invariants

- **Stops carry stable `id`s** assigned by `Tour.add_stop` from `tour.next_id` — a persisted, monotonic counter that never re-issues after a remove. Decoration maps key on `stop.id` (with array idx as fallback for tests that bypass `Tour`). Production code should never produce a stop without an id.
- **File paths are canonicalised once, on insert.** `state.add` calls `util.canonical` before passing the stop to `Tour.add_stop`. `Tour` uses plain string equality internally. macOS `/tmp` vs `/private/tmp` is handled at the boundary, not at every comparison site.
- **Drift detection has two flavours:**
  - *Buffer-side* — BufRead → `decoration.attach_buffer` → `anchor.attach` → `find_anchor_row` scans the loaded buffer ±20 lines.
  - *Offline* — `state.ensure_loaded` / `state.select` → `anchor.detect_drift_offline` reads the file from disk ±20 lines around the persisted lnum. Runs for stops whose files aren't currently buffers. This is why `:CodeTour open` and `:CodeTour list` show correct lnums for files you haven't opened yet.
- **State talks to decoration only.** `anchor` / `notes` / `signs` are private to `decoration`. Don't add new `state.lua → notes.lua` calls — go through `decoration.refresh_all` or add a verb to the facade.

## Extending the command surface

To add a subcommand: append an entry to the `subcommands` table in `plugin/codetour.lua`. The dispatcher and completion read from it automatically. Position-2 completion (e.g. tour names) is opt-in via `complete = tour_names` on the entry. The user-command name (`:CodeTour foo`) and the underlying Lua function name (`require("codetour").bar()`) can differ — they're tracked separately on purpose. The Lua API in `init.lua` is the stable surface for keymaps and scripts; the user-command names can evolve more freely.
