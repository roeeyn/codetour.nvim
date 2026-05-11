local M = {}

-- Decoration is the single seam state.lua talks to for buffer-side
-- presentation of a Tour. It wraps anchor (extmark-based position tracking),
-- notes (virt_lines), and signs (sign-column markers) so the orchestrator
-- doesn't have to call the three in lockstep. The three modules underneath
-- carry their own behaviour (drift handling, line-0 virt_lines workaround,
-- sign_text computation) and remain individually unit-testable.
--
-- All dependencies are required *inside* each function rather than at the
-- top of the module. This is deliberate: tests routinely do
-- `package.loaded["codetour.notes"] = nil` to force reloads, and a
-- top-level local would hold a stale reference past such a reset.

---Attach decoration for a single loaded buffer based on the tour's stops.
---Idempotent at the anchor layer (existing extmarks are reused); notes and
---signs are clear-and-rebuilt because the visible (idx/total) text and
---sign-column index depend on array position, which can shift on remove.
---@param bufnr integer
---@param tour CodeTour.Tour?
function M.attach_buffer(bufnr, tour)
  if tour == nil then
    return
  end
  require("codetour.anchor").attach(bufnr, tour.stops)
  require("codetour.notes").refresh(bufnr, tour.stops, tour.name)
  require("codetour.signs").refresh(bufnr, tour.stops)
end

---Re-render decoration across every loaded buffer. Pass nil to clear instead.
---@param tour CodeTour.Tour?
function M.refresh_all(tour)
  if tour == nil then
    M.detach_all()
    return
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.attach_buffer(bufnr, tour)
    end
  end
end

---Drop a single stop's decoration (anchor extmark, note, sign) across every
---buffer that tracked it. Used by state.remove so we don't have to detach +
---reattach every other stop just to drop one.
---@param stop_id integer
function M.detach_stop(stop_id)
  require("codetour.anchor").detach_stop(stop_id)
  require("codetour.notes").detach_stop(stop_id)
  require("codetour.signs").detach_stop(stop_id)
end

---Drop ALL decoration across every buffer. Used when switching tours.
function M.detach_all()
  require("codetour.anchor").detach_all()
  require("codetour.notes").detach_all()
  require("codetour.signs").detach_all()
end

---Toggle note visibility globally. Returns the new visibility state.
---@param tour CodeTour.Tour?
---@return boolean visible
function M.toggle_notes(tour)
  return require("codetour.notes").toggle(tour and tour.stops or {}, tour and tour.name or nil)
end

---Pull current extmark positions back into stop.lnum/col/context. Called
---before serialization (save) and before building the quickfix list so they
---reflect where the line *is*, not where it was when last persisted.
---@param stops CodeTour.Stop[]
function M.sync_positions(stops)
  require("codetour.anchor").refresh(stops)
end

return M
