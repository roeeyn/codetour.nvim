# Context

Domain vocabulary for codetour.nvim. Use these terms exactly when discussing
the plugin's architecture or behaviour. Architecture terms (Module, Interface,
Depth, Seam) live in the team's `improve-codebase-architecture` skill — this
file covers only domain-specific concepts.

## Terms

**Tour**
A named, ordered list of Stops, persisted as a single JSON file under the
configured `storage_path`. The unit a user creates, switches between, and
walks with the quickfix list. Tour is a pure data module — it has no
dependencies on storage, vim, or notify; state.lua orchestrates persistence
and side effects on its behalf.
_Avoid_: "path", "trail", "session" — they suggest temporary or implicit
structure, but a Tour is a deliberately-curated, named artifact.

**Stop**
One position in a Tour: file (absolute path in memory, relativised on save),
1-indexed line number, 0-indexed byte column, free-text note, and a trimmed
context snippet for cold-load re-anchoring.
_Avoid_: "bookmark", "mark" — those suggest unordered task-switching
primitives (harpoon, vim marks), which is the exact niche codetour is
positioned against.

**Note**
The user-authored prose attached to a Stop. Rendered as a virtual line above
the code. Empty string when not yet written.

**Active Tour**
The one Tour currently **open** — held in memory *and* visible. While a
tour is the Active Tour, its stops are decorated in every loaded buffer
(virt_lines + signs) and populated as the quickfix list. All mutations
(`:CodeTour add`, `:CodeTour remove`, `:CodeTour note`,
`:CodeTour rename`) target the Active Tour; they refuse with an error if
no tour is open. At most one tour is active at a time. `:CodeTour open`
makes a tour active; `:CodeTour close` releases it (decorations off, qf
restored, but the on-disk pointer is kept so the same tour reopens next
session if `auto_open_last_tour` is on).

**Anchor**
A Neovim extmark that tracks a Stop's live position in a loaded buffer.
Anchors update automatically as lines are inserted or deleted above the
Stop. Each loaded buffer has at most one Anchor per Stop.

**Drift**
The condition where a Stop's stored `lnum` no longer points at the line whose
content was recorded in its context snippet — typically because the file
was edited while nvim was closed. On cold-load the anchor module scans
±20 lines around the stored `lnum` for the matching context, then
re-anchors and notifies the user the Stop drifted.

**Decoration**
The visual layers rendered at a Stop's live position in a buffer: the note's
virtual line above the code, and the sign-column marker. Currently split
across `anchor.lua`, `notes.lua`, and `signs.lua` — a future deepening
would collapse those siblings behind one seam.

**Tour Quickfix**
A quickfix list whose title starts with `tour:`. Built by `:TourOpen` from the
Active Tour's stops, and mutated in place when the Active Tour changes.
Distinct from any non-tour quickfix list (`:grep` hits, LSP diagnostics) —
`:TourClose` restores whichever non-tour list was active before
`:TourOpen` snapshotted it.
