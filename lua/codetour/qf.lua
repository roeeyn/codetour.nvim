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

function M.open()
  state.ensure_loaded()
  if #state.data.stops == 0 then
    vim.notify("codetour: no stops to open", vim.log.levels.WARN)
    return
  end

  -- Pull the latest positions from extmarks before building qf items so
  -- the user lands on the actual current line, not the stale persisted one.
  local anchor = require "codetour.anchor"
  anchor.refresh(state.data.stops)

  -- Only snapshot the prior qf if we're not already in a tour.
  -- This makes :TourOpen idempotent: re-running it refreshes without losing the real prior list.
  local current_title = (vim.fn.getqflist { title = 1 } or {}).title or ""
  if not current_title:match "^tour:" then
    qf_backup = snapshot()
  end

  local items = {}
  for _, stop in ipairs(state.data.stops) do
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

  vim.cmd "cfirst"
  vim.cmd "cwindow"
end

---If a tour quickfix list is currently active (title starts with "tour:"),
---rebuild its items from `stops` so edits like :TourNoteEdit are reflected
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
