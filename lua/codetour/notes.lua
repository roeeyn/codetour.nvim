local M = {}

local NAMESPACE = vim.api.nvim_create_namespace "codetour_notes"

-- bufnr -> { [idx_in_state.data.stops] = note_extmark_id }
-- Separate from anchor's extmark map: position and note are conceptually different layers.
M._buf_marks = {}

-- Global visibility flag toggled by :TourNotesToggle.
M._visible = true

---Build the configured prefix string from {name}, {idx}, {total} placeholders.
---Unknown placeholders are left intact so typos are visible rather than silently
---vanishing.
---@param idx integer
---@param total integer
---@param tour_name string?
---@return string
local function format_prefix(idx, total, tour_name)
  local config = require "codetour.config"
  local fmt = config.opts.note_prefix or ""
  if fmt == "" then
    return ""
  end
  local replacements = {
    ["{name}"] = tour_name or "default",
    ["{idx}"] = tostring(idx),
    ["{total}"] = tostring(total),
  }
  local out = fmt:gsub("{%w+}", function(token)
    return replacements[token] or token
  end)
  return out
end

local function set_virt_lines(bufnr, idx, total, row, note, tour_name)
  local virt_lines = nil
  if note ~= nil and note ~= "" then
    -- Indent the note to match the line below so deeply-indented stops
    -- don't have their notes orphaned at column 0. Prefix follows the
    -- indent so it visually associates with the code block.
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local indent = line:match "^(%s*)" or ""
    local prefix = format_prefix(idx, total, tour_name)
    virt_lines = { { { indent .. prefix .. note, "CodetourNote" } } }
  end

  M._buf_marks[bufnr] = M._buf_marks[bufnr] or {}
  local existing = M._buf_marks[bufnr][idx]

  -- virt_lines_above = true at row 0 silently fails to render: nvim has no
  -- display row "above line 1" to draw into. For that one edge case fall
  -- back to rendering BELOW the line so the note remains visible. Visually
  -- inconsistent for line-1 stops only; alternative (sign / virt_text /
  -- nothing at all) would be more disruptive.
  local virt_lines_above = row > 0

  local opts = {
    virt_lines = virt_lines,
    virt_lines_above = virt_lines_above,
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
---@param tour_name string? Active path name; used for the {name} placeholder in note_prefix
function M.refresh(bufnr, stops, tour_name)
  bufnr = require("codetour.util").actual_bufnr(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not M._visible then
    return
  end

  -- Clear any existing note extmarks in this buffer's namespace and rebuild
  -- from scratch. This is the defensive shape because extmarks live in
  -- nvim-side per-buffer state while _buf_marks lives in Lua module memory --
  -- the two can drift apart on module reloads (lazy dev mode, :Lazy reload,
  -- package.loaded clears). Re-creating each time is cheap (extmarks are O(1))
  -- and makes refresh self-healing regardless of how we got here.
  vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
  M._buf_marks[bufnr] = {}

  local anchor = require "codetour.anchor"
  local total = #stops
  for idx, stop in ipairs(stops) do
    local row = anchor.row_of(bufnr, idx)
    if row ~= nil then
      set_virt_lines(bufnr, idx, total, row, stop.note or "", tour_name)
    end
  end
end

---Walk every buffer the anchor module is tracking and refresh notes there.
---Useful after toggling visibility on, or after a change that affects multiple files.
---@param stops CodeTour.Stop[]
---@param tour_name string?
function M.refresh_all(stops, tour_name)
  if not M._visible then
    return
  end
  local anchor = require "codetour.anchor"
  for bufnr, _ in pairs(anchor._buf_extmarks) do
    M.refresh(bufnr, stops, tour_name)
  end
end

---Flip visibility. Hides → clears virt_lines extmarks. Shows → re-renders.
---@param stops CodeTour.Stop[]
---@param tour_name string?
---@return boolean visible The new visibility state
function M.toggle(stops, tour_name)
  M._visible = not M._visible
  if M._visible then
    M.refresh_all(stops, tour_name)
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
