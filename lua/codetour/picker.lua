local log = require "codetour.log"
local M = {}

---Open a picker over the active tour's stops. Default action: jump to that stop.
---Uses `vim.ui.select`, which dressing.nvim / Telescope's ui-select extension /
---noice.nvim transparently upgrade to a richer picker UI if installed.
function M.stops()
  local state = require "codetour.state"
  state.ensure_loaded()

  if state.data.active_tour == nil then
    log.warn "codetour: no active tour. Use :CodeTour create or :CodeTour select first."
    return
  end

  local tour = state.data.active_tour
  if #tour.stops == 0 then
    log.warn(string.format("codetour: tour '%s' has no stops yet", tour.name))
    return
  end

  local entries = {}
  for idx, stop in ipairs(tour.stops) do
    table.insert(entries, {
      idx = idx,
      stop = stop,
      display = string.format(
        "[%d] %s:%d  ─  %s",
        idx,
        vim.fn.fnamemodify(stop.file, ":~:."),
        stop.lnum or 1,
        stop.note ~= "" and stop.note or "(no note)"
      ),
    })
  end

  vim.ui.select(entries, {
    prompt = string.format("Stops in '%s' (%d total)", tour.name, #entries),
    format_item = function(entry)
      return entry.display
    end,
  }, function(entry)
    if entry == nil then
      return
    end
    -- Verify the file still exists; otherwise notify rather than fail loudly.
    if vim.fn.filereadable(entry.stop.file) == 0 then
      log.warn(string.format("codetour: file no longer exists: %s", entry.stop.file))
      return
    end
    vim.cmd("edit " .. vim.fn.fnameescape(entry.stop.file))
    pcall(vim.api.nvim_win_set_cursor, 0, { entry.stop.lnum or 1, entry.stop.col or 0 })
    vim.cmd "normal! zz"
  end)
end

---Open a picker over available tours. Default action: switch to that tour.
function M.tours()
  local state = require "codetour.state"
  state.ensure_loaded()

  local tours = state.tours_with_meta()
  if #tours == 0 then
    log.warn "codetour: no tours yet. Use :CodeTour create <name> to create one."
    return
  end

  local entries = {}
  for _, tour in ipairs(tours) do
    local marker = tour.is_active and " (active)" or ""
    table.insert(entries, {
      tour = tour,
      display = string.format("%s — %d stops%s", tour.name, tour.stops_count, marker),
    })
  end

  vim.ui.select(entries, {
    prompt = "Select a tour",
    format_item = function(entry)
      return entry.display
    end,
  }, function(entry)
    if entry == nil then
      return
    end
    state.select(entry.tour.name)
  end)
end

return M
