local M = {}

local NAMESPACE = vim.api.nvim_create_namespace "codetour_notes"

-- bufnr -> { [idx_in_state.data.stops] = note_extmark_id }
-- Separate from anchor's extmark map: position and note are conceptually different layers.
M._buf_marks = {}

-- Global visibility flag toggled by :TourNotesToggle.
M._visible = true

local function set_virt_lines(bufnr, idx, row, note)
  local virt_lines = nil
  if note ~= nil and note ~= "" then
    -- Indent the note to match the line below so deeply-indented stops
    -- don't have their notes orphaned at column 0.
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local indent = line:match "^(%s*)" or ""
    virt_lines = { { { indent .. note, "CodetourNote" } } }
  end

  M._buf_marks[bufnr] = M._buf_marks[bufnr] or {}
  local existing = M._buf_marks[bufnr][idx]
  local opts = {
    virt_lines = virt_lines,
    virt_lines_above = true,
  }
  if existing then
    opts.id = existing
  end

  local id = vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, row, 0, opts)
  M._buf_marks[bufnr][idx] = id
end

---Render notes for any stops whose anchor is in this buffer.
---Reads each stop's current row from anchor.row_of(); if nil (no extmark), skip.
---@param bufnr integer
---@param stops CodeTour.Stop[]
function M.refresh(bufnr, stops)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not M._visible then
    return
  end

  local anchor = require "codetour.anchor"
  for idx, stop in ipairs(stops) do
    local row = anchor.row_of(bufnr, idx)
    if row ~= nil then
      set_virt_lines(bufnr, idx, row, stop.note or "")
    end
  end
end

---Walk every buffer the anchor module is tracking and refresh notes there.
---Useful after toggling visibility on, or after a change that affects multiple files.
---@param stops CodeTour.Stop[]
function M.refresh_all(stops)
  if not M._visible then
    return
  end
  local anchor = require "codetour.anchor"
  for bufnr, _ in pairs(anchor._buf_extmarks) do
    M.refresh(bufnr, stops)
  end
end

---Flip visibility. Hides → clears virt_lines extmarks. Shows → re-renders.
---@param stops CodeTour.Stop[]
---@return boolean visible The new visibility state
function M.toggle(stops)
  M._visible = not M._visible
  if M._visible then
    M.refresh_all(stops)
  else
    M.detach_all()
  end
  return M._visible
end

---Drop every note extmark across every buffer.
---Called by state.start() before resetting the stop list.
function M.detach_all()
  for bufnr, _ in pairs(M._buf_marks) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, NAMESPACE, 0, -1)
    end
  end
  M._buf_marks = {}
end

return M
