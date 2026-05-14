local state = require "codetour.state"
local git = require "codetour.git"
local config = require "codetour.config"
local M = {}

-- Module-local snapshot of the user's prior quickfix list.
-- Set by M.open(), cleared by M.close(); persists across calls because
-- modules are cached in package.loaded for the lifetime of the session.
local qf_backup = nil

local function snapshot()
  local prev = vim.fn.getqflist { items = 1, title = 1 }
  return {
    items = prev.items or {},
    title = prev.title or "",
  }
end

---Populate the quickfix list with the active tour's stops and (unless
---`skip_jump` is true) schedule `cfirst` + `cwindow`. Bails early with a
---warn if no stops to show. Snapshots the *prior* qf list once on first
---entry into a tour, so `close()` can restore it later.
---@param skip_jump boolean? if true, populate qf only — caller handles navigation
function M.open(skip_jump)
  state.ensure_loaded()
  local stops = state.stops()
  if #stops == 0 then
    require("codetour.log").warn "codetour: no stops to open"
    return
  end

  -- Pull the latest positions from extmarks before building qf items so
  -- the user lands on the actual current line, not the stale persisted one.
  require("codetour.decoration").sync_positions(stops)

  -- Only snapshot the prior qf if we're not already in a tour.
  -- This makes :CodeTour open idempotent: re-running it refreshes without losing the real prior list.
  local current_title = (vim.fn.getqflist { title = 1 } or {}).title or ""
  if not current_title:match "^tour:" then
    qf_backup = snapshot()
  end

  local items = {}
  for _, stop in ipairs(stops) do
    table.insert(items, {
      filename = stop.file,
      lnum = stop.lnum,
      col = stop.col + 1, -- qf wants 1-indexed col; we store 0-indexed
      text = stop.note ~= "" and stop.note or "(no note)",
    })
  end

  local info = git.info()
  local title = string.format("tour:%s", info and info.branch or "no-branch")
  vim.fn.setqflist({}, " ", { title = title, items = items })

  -- Defer the side-effectful navigation. `cfirst` opens the first stop's
  -- file, which triggers BufRead — and in configs with heavy BufRead
  -- handlers (LSP attach, treesitter parse, gitsigns/blame, etc.) this
  -- can take 1-2 seconds synchronously. Running it inside the user-command
  -- callback blocks GUI redraws for that duration; in --embed UIs like
  -- Neovide the editor looks completely frozen. vim.schedule lets the
  -- callback return immediately, the cmdline clears, then the navigation
  -- runs on the next event-loop tick.
  if not skip_jump then
    vim.schedule(function()
      vim.cmd "cfirst"
      vim.cmd "cwindow"
    end)
  end
end

---If a tour quickfix list is currently active (title starts with "tour:"),
---rebuild its items from `stops` so edits like :CodeTour note are reflected
---in the qf view immediately. No-op if the user is on some other qf list.
---@param stops CodeTour.Stop[]
function M.update_if_tour_active(stops)
  local current = vim.fn.getqflist { title = 1, idx = 0 }
  local title = (current and current.title) or ""
  if not title:match "^tour:" then
    return
  end

  local items = {}
  for _, stop in ipairs(stops) do
    table.insert(items, {
      filename = stop.file,
      lnum = stop.lnum,
      col = stop.col + 1,
      text = stop.note ~= "" and stop.note or "(no note)",
    })
  end

  -- 'r' replaces items in the current list. nr = 0 is required for `idx` to
  -- be honored — without it nvim silently ignores the idx and resets the qf
  -- cursor to entry 1. We also clamp idx to the new list length so it stays
  -- valid after a remove that shrinks the list.
  local what = { nr = 0, items = items, title = title }
  if #items > 0 then
    what.idx = math.max(1, math.min(current.idx or 1, #items))
  end
  vim.fn.setqflist({}, "r", what)
end

function M.close()
  if qf_backup == nil then
    vim.fn.setqflist({}, "r", { items = {}, title = "" })
  else
    vim.fn.setqflist({}, "r", {
      items = qf_backup.items,
      title = qf_backup.title,
    })
    qf_backup = nil
  end

  if config.opts.close_qf_on_tour_close then
    vim.cmd "cclose"
  end
end

return M
