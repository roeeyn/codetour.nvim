---
name: create-codetour-tour
description: Create or amend a codetour.nvim tour — a named, ordered trail of stops through a codebase, persisted as JSON at <repo>/.codetour/<name>.json and walked via the Neovim quickfix list. Use this skill whenever the user asks to "show the X flow", "trace the X flow", "walk me through how Y works", "create a tour of Z", "document the auth/payment/login/signup/dispatch flow", "annotate the path from A to B to C", or "add a stop to an existing tour". Trigger even when the user doesn't explicitly say "tour" — anytime they want to capture a sequence of related call sites as a guided, navigable walkthrough of a codebase (3–7 stops, in execution order, each with a "why this matters" note), this is the right skill.
---

# Creating and amending codetour.nvim tours

A **tour** is a named, ordered trail of **stops** through a codebase. Each stop is a position in a file with an annotated note explaining *why this stop matters*. Tours are persisted as JSON at `<repo>/.codetour/<tour-name>.json` and walked using the Neovim quickfix list (`:cnext` / `:cprev`).

This skill teaches you to:
1. Write the on-disk JSON format correctly.
2. Author a new tour from a prompt like *"show me the auth flow"*.
3. Amend an existing tour (add / remove / reorder stops).
4. Validate the result before handing it back.

## On-disk format

A tour file lives at `<repo>/.codetour/<tour-name>.json`. Schema:

```json
{
  "version": 2,
  "name": "auth-flow",
  "next_id": 4,
  "stops": [
    {
      "id": 1,
      "file": "src/api/handlers/login.ts",
      "lnum": 23,
      "col": 0,
      "note": "entry — validates the credentials payload before dispatch",
      "context": "export async function loginHandler(req, res) {"
    },
    {
      "id": 2,
      "file": "src/auth/jwt.ts",
      "lnum": 45,
      "col": 0,
      "note": "signs the JWT with the per-user expiry; downstream relies on the `exp` claim",
      "context": "function signToken(user) {"
    },
    {
      "id": 3,
      "file": "src/middleware/auth.ts",
      "lnum": 12,
      "col": 0,
      "note": "guards every protected route — req.user is populated here, not in handlers",
      "context": "export const requireAuth = (req, res, next) => {"
    }
  ]
}
```

Field rules:

| Field | Rule |
|---|---|
| `version` | Always `2` (current schema). |
| `name` | Tour identifier. Must not contain `/`, `\`, or `:`. |
| `next_id` | Monotonic counter for assigning IDs to *future* stops. Must be `> max(stop.id)`. |
| `stops` | Array, in walking order. |
| `stop.id` | Unique within the tour. Gaps are allowed (e.g., after a removal). |
| `stop.file` | **Relative to the git root**. Never absolute. Stops in files outside the git root are not supported. |
| `stop.lnum` | 1-indexed line number. |
| `stop.col` | 0-indexed byte column. Use `0` if you don't have a specific column. |
| `stop.note` | Short prose: *why this stop matters*. One sentence ideal. See the note-writing rules below. |
| `stop.context` | Trimmed first ≤60 chars of the **actual line at `lnum`**. Used at runtime to recover the stop's position if lines drift above it. |

A second file at `<repo>/.codetour/_active_tour.txt` is a plain-text pointer (one line, the tour's name, no extension). This is the tour `:CodeTour open` operates on. Only write it if the user explicitly wants the new tour to be the active one.

### Why `context` matters so much

`context` is a fingerprint of the line, not a description of it. The plugin uses it to handle two scenarios:

- **Lines drift in the live buffer** (insert / delete above the stop). Extmarks track the position automatically; `context` is a fallback.
- **The file was edited externally while Neovim was closed.** On reopen, the plugin scans ±20 lines around the stored `lnum` for a line whose trimmed content equals `context`. If found, it re-anchors there. If not, the stop stays at the original `lnum` but in the wrong place.

If you guess or paraphrase `context` (e.g., write `"the login handler"` instead of the actual line `"export async function loginHandler(req, res) {"`), Neovim immediately flags the stop as drifted the moment it opens the file. **Always Read the file to capture the literal line content.**

## Authoring a new tour

The brief: a user says something like *"show me the auth flow in this api"* or *"create a tour through how requests get dispatched to handlers"*. Goal: produce a tour file that walks them from entry to terminus through the most informative ≤7 stops, in execution order.

**Step 1 — Identify candidates.** Use Grep / Glob / Read to find the functions, methods, or entry points the user's prompt refers to. For "auth flow", that's usually: route handler → token issuance → middleware that validates on subsequent requests → maybe the user-context attachment. For an unfamiliar repo, start by reading the README / top-level entry to orient yourself, then drill into the relevant subsystem.

**Step 2 — Order by execution flow.** Tours are walked in array order. Stop 1 is what the user sees first; `:cnext` advances. The order should follow the actual control flow — request enters here, gets validated there, dispatches to this, ends up persisted in that — not the alphabetical-file order.

**Step 3 — Read each file at the target line** to capture `context`. This is the single most important step. The line at `lnum` must be read from disk (Read tool), trimmed (strip leading/trailing whitespace), and truncated to ≤60 chars. **Never guess `context`.**

**Step 4 — Write the note.** One short sentence focused on *why this stop matters*. Names already say *what*; the note should add the *why*: the surprise, the load-bearing decision, the constraint that's easy to miss.

Examples:
- ✗ `"calls validateToken()"` — describes *what*; redundant with the function name
- ✓ `"first place a request becomes 'authenticated' — everything downstream assumes req.user exists"`
- ✗ `"handles login"` — too vague
- ✓ `"rate-limits on a sliding window; the cache key includes the IP so private networks share buckets"`

**Step 5 — Assign IDs.** Sequential starting from `1` is conventional. Set `next_id = (highest id) + 1`.

**Step 6 — Write the JSON file** to `<repo>/.codetour/<tour-name>.json`. Create the `.codetour` directory if it doesn't exist.

**Step 7 — (Optional) Activate.** If the user wants to immediately walk the tour with `:CodeTour open`, write the tour name to `<repo>/.codetour/_active_tour.txt`. If a different tour is already active and the user didn't ask to switch, leave the pointer file alone — they may be in the middle of walking it.

**Stop count.** Sweet spot is 3–7 stops. Fewer than 3 isn't really a trail; more than 7 starts to feel like documentation. If the user's request seems to demand more, **ask whether to split into two tours** (e.g., `auth-login-flow` and `auth-middleware-flow`) rather than dump everything into one.

## Amending an existing tour

The brief: *"add a stop at the JWT verification call to the auth-flow tour"* or *"remove the third stop from the dispatch-flow tour"*.

1. **Find the tour.** If the user names it, read `<repo>/.codetour/<name>.json`. If they say "the active tour" or don't name one, read `<repo>/.codetour/_active_tour.txt` first to discover the name.
2. **Locate the change.** Grep for the call site / function / line the user described.
3. **Read the file** at that line to capture `context` (same rules as authoring — trimmed, ≤60 chars, literal line content).
4. **Modify the `stops` array.**
   - *Adding a stop:* set the new stop's `id` to the file's current `next_id`, then increment `next_id` in the JSON. By default append to the end; if the user said "between stop 2 and 3" or "after the JWT signing", splice in at the appropriate index.
   - *Removing a stop:* drop it from the array. **Do not** decrement `next_id` — the counter only ever moves forward, on purpose (so a removed ID is never reused; anything that captured it stays correct).
   - *Reordering:* rearrange the array. `id`s stay attached to their stops; the visible "(idx/total)" prefix follows array position, not id.
5. **Write the file back.**

## Self-check before handing back

Re-read the file you just wrote and verify:

- For every stop, the `context` field equals the trimmed (≤60 char) version of the *actual* line at `lnum`. Re-Read each `stop.file` and compare. If even one mismatches, fix it — otherwise Neovim shows drift warnings the moment the user opens the file.
- All `file` paths are relative to the git root (no leading `/`).
- `next_id > max(stop.id)`.
- No two stops share the same `(file, lnum)` — the plugin rejects this on load.
- Tour `name` contains no `/`, `\`, or `:`.
- JSON parses (no trailing commas, no comments).
- The `.codetour/` directory and tour file exist.

When everything checks out, tell the user the tour was created (or amended) and point at the file path. If they want to walk it immediately and you didn't update `_active_tour.txt`, suggest they run `:CodeTour select <name>` followed by `:CodeTour open`.

## Anti-patterns

- **Don't paraphrase `context`.** It's a fingerprint, not a description. Read the file.
- **Don't write notes that describe *what*.** A function named `validateToken` doesn't need a note saying "validates the token." Write the *why*: what's surprising, what's load-bearing, what the reader would miss.
- **Don't pack 20 stops into one tour.** Three to seven is the sweet spot. Ask the user to split if there's more.
- **Don't use absolute paths in `file`.** Always relative to the git root. If the target file is outside the repo, the stop can't exist.
- **Don't invent line numbers.** Always Grep-then-Read to confirm before writing.
- **Don't overwrite `_active_tour.txt` unsolicited.** The user may be walking another tour right now.
- **Don't reuse IDs.** Even after a removal, `next_id` keeps climbing. This is intentional — anything that captured the old ID (an in-memory state, an open quickfix list) stays correct.

## Domain glossary (canonical defs)

If the user is working inside the `codetour.nvim` repo itself, the file `CONTEXT.md` at the repo root is the definitive glossary for `Tour`, `Stop`, `Note`, `Active Tour`, `Anchor`, `Drift`, `Decoration`, `Tour Quickfix`. Use the same vocabulary in any documentation or commit messages you generate.
