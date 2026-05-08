local storage = require "codetour.storage"
local M = {}

---@class CodeTour.Stop
---@field file string Absolute path to the file the stop lives in
---@field lnum integer 1-indexed line number (matches nvim_win_get_cursor)
---@field col integer 0-indexed byte column (matches nvim_win_get_cursor)
---@field note string User's prose for this stop; empty string if no note was given
---@field context string Trimmed snippet (~60 chars) of the line content; used for cold-load re-anchor

---@class CodeTour.State
---@field path_name string? Active path's name; nil before any :TourStart/:TourAdd
---@field stops CodeTour.Stop[] Ordered list of stops in the active path
---@field loaded boolean Whether ensure_loaded() has run for the current branch

---@type CodeTour.State
M.data = {
  path_name = nil,
  stops = {},
  loaded = false,
}

local function save()
  -- Refresh stops' lnum/col from any live extmarks so the persisted positions
  -- reflect any in-session shifts (lines inserted/deleted above the stop).
  local anchor = require "codetour.anchor"
  anchor.refresh(M.data.stops)
  storage.save(M.data.path_name, M.data.stops)
end

-- Load state from disk on first access. Cheap no-op on subsequent calls.
function M.ensure_loaded()
  if M.data.loaded then
    return
  end
  M.data.loaded = true -- mark first to avoid re-entrancy on errors
  local loaded = storage.load()
  if loaded then
    M.data.path_name = loaded.path_name
    M.data.stops = loaded.stops
  end
end

---@param name string? Optional path name; defaults to "default"
function M.start(name)
  -- Drop every extmark and note before clearing the stop list so buffers
  -- aren't left with orphan markers pointing at indexes that no longer exist.
  local anchor = require "codetour.anchor"
  local notes = require "codetour.notes"
  anchor.detach_all()
  notes.detach_all()
  M.data.path_name = name or "default"
  M.data.stops = {}
  M.data.loaded = true -- explicitly initialized; no need to read from disk
  save()
  vim.notify(string.format("codetour: started path '%s'", M.data.path_name), vim.log.levels.INFO)
end

---@param note string? Optional note describing why this stop matters
function M.add(note)
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    vim.notify("codetour: current buffer has no file", vim.log.levels.WARN)
    return
  end
  M.ensure_loaded()

  -- Refresh first so the dedupe check below uses *current* extmark positions
  -- rather than possibly-stale stored lnums (e.g. after editing in this session).
  local anchor = require "codetour.anchor"
  anchor.refresh(M.data.stops)

  local cursor = vim.api.nvim_win_get_cursor(0)
  local lnum, col = cursor[1], cursor[2]

  -- Idempotent dedupe: refuse to create two stops at the same (file, lnum).
  local util = require "codetour.util"
  local target_file = util.canonical(file)
  for _, existing in ipairs(M.data.stops) do
    if util.canonical(existing.file) == target_file and existing.lnum == lnum then
      vim.notify(
        string.format("codetour: a stop already exists at %s:%d", vim.fn.fnamemodify(file, ":t"), lnum),
        vim.log.levels.WARN
      )
      return
    end
  end

  if M.data.path_name == nil then
    M.data.path_name = "default"
  end
  local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
  table.insert(M.data.stops, {
    file = file,
    lnum = lnum,
    col = col,
    note = note or "",
    context = util.trim_context(line),
  })
  -- Attach an extmark to the just-added stop so future edits track its position.
  anchor.attach(0, M.data.stops)
  -- Render the note as a virt_line above the stop's row.
  local notes = require "codetour.notes"
  notes.refresh(0, M.data.stops, M.data.path_name)
  save()
  vim.notify(
    string.format("codetour: stop #%d added at %s:%d", #M.data.stops, vim.fn.fnamemodify(file, ":t"), lnum),
    vim.log.levels.INFO
  )
end

---Find the index of the stop in `stops` nearest the cursor in the current buffer.
---Same-line preferred (distance 0), then nearest by absolute line distance.
---Only considers stops whose file matches the current buffer's path.
---@param stops CodeTour.Stop[]
---@return integer? idx 1-based index into `stops`, or nil if no match
local function nearest_stop_idx_in_buf(stops)
  local util = require "codetour.util"
  local current_path = util.canonical(vim.api.nvim_buf_get_name(0))
  if current_path == nil then
    return nil
  end
  local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
  local best_idx, best_dist = nil, math.huge
  for idx, stop in ipairs(stops) do
    if util.canonical(stop.file) == current_path then
      local dist = math.abs((stop.lnum or 1) - cursor_lnum)
      if dist < best_dist then
        best_idx = idx
        best_dist = dist
      end
    end
  end
  return best_idx
end

---Replace the note of the stop nearest the cursor in the current buffer.
---Empty `text` is rejected with a usage notify; we don't use it as a "clear" sentinel
---because it's indistinguishable from a typo (no way to know intent).
---@param text string New note text; empty/nil = error
function M.edit_note(text)
  if text == nil or text == "" then
    vim.notify("codetour: usage: :TourNoteEdit <new text>", vim.log.levels.WARN)
    return
  end

  M.ensure_loaded()
  local idx = nearest_stop_idx_in_buf(M.data.stops)
  if idx == nil then
    vim.notify("codetour: no stop in current buffer", vim.log.levels.WARN)
    return
  end

  M.data.stops[idx].note = text
  local notes = require "codetour.notes"
  notes.refresh(0, M.data.stops, M.data.path_name)
  -- Sync the quickfix list so an open tour qf reflects the new note text
  -- without requiring the user to re-run :TourOpen.
  local qf = require "codetour.qf"
  qf.update_if_tour_active(M.data.stops)
  save()
  vim.notify(string.format("codetour: stop #%d note updated", idx), vim.log.levels.INFO)
end

function M.dump()
  M.ensure_loaded()
  print(vim.inspect(M.data))
end

---Remove the stop nearest the cursor in the current buffer.
---After removal, all subsequent stops' indices shift down by one, so we drop
---and re-attach all extmarks so the index→extmark_id maps stay correct.
function M.remove()
  M.ensure_loaded()
  local idx = nearest_stop_idx_in_buf(M.data.stops)
  if idx == nil then
    vim.notify("codetour: no stop in current buffer", vim.log.levels.WARN)
    return
  end

  -- Refresh positions so the persisted state captures the latest line numbers
  -- of stops we're keeping.
  local anchor = require "codetour.anchor"
  anchor.refresh(M.data.stops)

  local removed = M.data.stops[idx]
  local removed_label = string.format("%s:%d", vim.fn.fnamemodify(removed.file, ":t"), removed.lnum)
  table.remove(M.data.stops, idx)

  -- Indices shifted; rebuild extmark/note tracking from scratch across all
  -- loaded buffers that hold stops.
  local notes = require "codetour.notes"
  anchor.detach_all()
  notes.detach_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      anchor.attach(bufnr, M.data.stops)
      notes.refresh(bufnr, M.data.stops, M.data.path_name)
    end
  end

  local qf = require "codetour.qf"
  qf.update_if_tour_active(M.data.stops)

  save()
  vim.notify(
    string.format("codetour: stop #%d removed (%s); %d stops remaining", idx, removed_label, #M.data.stops),
    vim.log.levels.INFO
  )
end

return M
