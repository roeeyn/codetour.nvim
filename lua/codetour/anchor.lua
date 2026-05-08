local M = {}

local NAMESPACE = vim.api.nvim_create_namespace "codetour"
local SEARCH_RADIUS = 20

-- bufnr -> { [idx_in_state.data.stops] = extmark_id }
-- Module-local because the map's lifetime is the session, and only this module
-- ever needs to read or write it.
M._buf_extmarks = {}

local function buf_path(bufnr)
  local util = require "codetour.util"
  return util.canonical(vim.api.nvim_buf_get_name(bufnr))
end

---Find the row (0-indexed) where this stop should anchor.
---Order of preference:
---  1. The stored line (if its content still matches `stored_context`)
---  2. The closest line within ±SEARCH_RADIUS whose content matches
---  3. Fall back to the stored line (no match found; stops persists at original lnum)
---@param bufnr integer
---@param stored_lnum integer 1-indexed line number
---@param stored_context string Trimmed line snippet captured when the stop was last synced
---@param line_count integer
---@return integer row 0-indexed row to anchor at
---@return boolean drifted true if we re-anchored away from stored_lnum
local function find_anchor_row(bufnr, stored_lnum, stored_context, line_count)
  local stored_row = math.max(0, (stored_lnum or 1) - 1)
  stored_row = math.min(stored_row, math.max(0, line_count - 1))

  -- Without a context snippet (or empty buffer), we can't search; trust the lnum.
  if stored_context == nil or stored_context == "" or line_count == 0 then
    return stored_row, false
  end

  local util = require "codetour.util"

  local current = vim.api.nvim_buf_get_lines(bufnr, stored_row, stored_row + 1, false)[1] or ""
  if util.trim_context(current) == stored_context then
    return stored_row, false
  end

  -- Scan outward from the stored row so the closest matching line wins.
  for offset = 1, SEARCH_RADIUS do
    for _, candidate in ipairs { stored_row - offset, stored_row + offset } do
      if candidate >= 0 and candidate < line_count then
        local line = vim.api.nvim_buf_get_lines(bufnr, candidate, candidate + 1, false)[1] or ""
        if util.trim_context(line) == stored_context then
          return candidate, true
        end
      end
    end
  end

  return stored_row, false
end

---Attach extmarks for any stops whose file matches this buffer's path.
---On a cold load (extmark doesn't exist yet), uses `stored_context` to detect
---whether the line drifted while nvim wasn't running, and re-anchors if so.
---Idempotent: skips stops already tracked for this buffer.
---@param bufnr integer
---@param stops CodeTour.Stop[]
function M.attach(bufnr, stops)
  bufnr = require("codetour.util").actual_bufnr(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local path = buf_path(bufnr)
  if path == nil then
    return
  end

  M._buf_extmarks[bufnr] = M._buf_extmarks[bufnr] or {}

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for idx, stop in ipairs(stops) do
    local util = require "codetour.util"
    if M._buf_extmarks[bufnr][idx] == nil and util.canonical(stop.file) == path then
      local original_lnum = stop.lnum or 1
      local row, drifted = find_anchor_row(bufnr, original_lnum, stop.context, line_count)
      local col = math.max(0, stop.col or 0)
      local id = vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, row, col, {})
      M._buf_extmarks[bufnr][idx] = id
      if drifted then
        stop.lnum = row + 1
        stop.col = 0 -- column meaning is unclear after drift; reset to start of line
        vim.notify(
          string.format("codetour: stop #%d drifted from line %d to %d", idx, original_lnum, stop.lnum),
          vim.log.levels.INFO
        )
      end
    end
  end
end

---Read live extmark positions and refresh the matching stops' lnum/col/context
---(1-indexed lnum, 0-indexed col). Called before save() and before qf-build.
---@param stops CodeTour.Stop[]
function M.refresh(stops)
  local util = require "codetour.util"
  for bufnr, marks in pairs(M._buf_extmarks) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      for idx, id in pairs(marks) do
        local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, NAMESPACE, id, {})
        if pos and pos[1] then
          local stop = stops[idx]
          if stop then
            stop.lnum = pos[1] + 1
            stop.col = pos[2]
            local lines = vim.api.nvim_buf_get_lines(bufnr, pos[1], pos[1] + 1, false)
            if lines and lines[1] then
              stop.context = util.trim_context(lines[1])
            end
          end
        end
      end
    end
  end
end

---Returns the 0-indexed row where this stop's extmark currently lives, or nil
---if the stop isn't tracked in this buffer (or the buffer is invalid).
---Used by notes.lua to render virt_lines at the stop's live position.
---@param bufnr integer
---@param idx integer
---@return integer? row 0-indexed
function M.row_of(bufnr, idx)
  bufnr = require("codetour.util").actual_bufnr(bufnr)
  local marks = M._buf_extmarks[bufnr]
  if marks == nil then
    return nil
  end
  local id = marks[idx]
  if id == nil then
    return nil
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, NAMESPACE, id, {})
  return pos and pos[1] or nil
end

---Drop the extmarks for one buffer (used when the buffer is being unloaded).
---@param bufnr integer
function M.detach(bufnr)
  bufnr = require("codetour.util").actual_bufnr(bufnr)
  if M._buf_extmarks[bufnr] then
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, NAMESPACE, 0, -1)
    end
    M._buf_extmarks[bufnr] = nil
  end
end

---Drop every extmark this plugin has set across every buffer.
---Called by state.start() before resetting the stop list.
function M.detach_all()
  for bufnr, _ in pairs(M._buf_extmarks) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, NAMESPACE, 0, -1)
    end
  end
  M._buf_extmarks = {}
end

return M
