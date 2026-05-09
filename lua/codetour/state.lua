local storage = require "codetour.storage"
local log = require "codetour.log"
local M = {}

---@class CodeTour.Stop
---@field file string Absolute path to the file the stop lives in
---@field lnum integer 1-indexed line number (matches nvim_win_get_cursor)
---@field col integer 0-indexed byte column (matches nvim_win_get_cursor)
---@field note string User's prose for this stop; empty string if no note was given
---@field context string Trimmed snippet (~60 chars) of the line content; used for cold-load re-anchor

---@class CodeTour.State
---@field active_tour string? Name of the tour currently in memory; nil = none active
---@field stops CodeTour.Stop[] Stops of the active tour
---@field loaded boolean Whether ensure_loaded() has run

---@type CodeTour.State
M.data = {
  active_tour = nil,
  stops = {},
  loaded = false,
}

local function save()
  if M.data.active_tour == nil then
    return
  end
  local anchor = require "codetour.anchor"
  anchor.refresh(M.data.stops)
  storage.save(M.data.active_tour, M.data.stops)
end

---Load the last-active tour (if any) on first call. Cheap no-op afterwards.
---If the active-pointer references a missing/corrupt tour, clears the pointer
---and notifies — the user isn't stuck with a phantom active tour.
function M.ensure_loaded()
  if M.data.loaded then
    return
  end
  M.data.loaded = true

  local active = storage.read_active()
  if active == nil then
    return
  end

  local loaded = storage.load(active)
  if loaded == nil then
    log.warn(string.format("codetour: active tour '%s' couldn't be loaded; clearing active pointer", active))
    storage.write_active(nil)
    return
  end

  M.data.active_tour = loaded.name
  M.data.stops = loaded.stops
end

local function require_active()
  if M.data.active_tour == nil then
    log.warn "codetour: no active tour. Use :TourCreate <name> or :TourSelect <name> first."
    return false
  end
  return true
end

---Drop extmarks/notes/signs across all loaded buffers and reset in-memory state.
local function reset_in_memory()
  local anchor = require "codetour.anchor"
  local notes = require "codetour.notes"
  local signs = require "codetour.signs"
  anchor.detach_all()
  notes.detach_all()
  signs.detach_all()
  M.data.active_tour = nil
  M.data.stops = {}
end

---Re-attach anchors and re-render notes/signs across all loaded buffers, then sync qf.
local function rehydrate_all_buffers()
  local anchor = require "codetour.anchor"
  local notes = require "codetour.notes"
  local signs = require "codetour.signs"
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      anchor.attach(bufnr, M.data.stops)
      notes.refresh(bufnr, M.data.stops, M.data.active_tour)
      signs.refresh(bufnr, M.data.stops)
    end
  end
  local qf = require "codetour.qf"
  qf.update_if_tour_active(M.data.stops)
end

---Create a new empty tour and make it active. Refuses if name already exists
---or contains characters that would conflict with the on-disk filename.
---@param name string?
function M.create(name)
  if name == nil or name == "" then
    log.warn "codetour: usage: :TourCreate <name>"
    return
  end
  -- Refuse path-unsafe characters at create time rather than silently
  -- sanitizing them, which could collide on disk (e.g. "auth/v2" and
  -- "auth_v2" would both become auth_v2.json).
  if name:match "[/\\:]" then
    log.warn(string.format("codetour: tour name '%s' contains invalid characters (/ \\ :)", name))
    return
  end
  M.ensure_loaded()

  for _, existing in ipairs(storage.list_tours()) do
    if existing == name then
      log.warn(string.format("codetour: tour '%s' already exists; use :TourSelect to switch", name))
      return
    end
  end

  reset_in_memory()
  M.data.active_tour = name
  M.data.stops = {}
  storage.save(name, {})
  storage.write_active(name)

  -- No stops to render yet, but sync qf in case a tour view was active.
  local qf = require "codetour.qf"
  qf.update_if_tour_active(M.data.stops)

  log.info(string.format("codetour: created tour '%s'", name))
end

---Switch to an existing tour. No-op with a warning if `name` doesn't exist.
---@param name string?
function M.select(name)
  if name == nil or name == "" then
    log.warn "codetour: usage: :TourSelect <name>"
    return
  end
  M.ensure_loaded()

  local loaded = storage.load(name)
  if loaded == nil then
    log.warn(string.format("codetour: tour '%s' not found", name))
    return
  end

  reset_in_memory()
  M.data.active_tour = loaded.name
  M.data.stops = loaded.stops
  storage.write_active(name)
  rehydrate_all_buffers()

  log.info(string.format("codetour: selected tour '%s' (%d stops)", name, #M.data.stops))
end

---Delete a tour by name. Confirms first. If the deleted tour is the active
---one, clears in-memory state and the active-pointer file.
---@param name string?
function M.delete(name)
  if name == nil or name == "" then
    log.warn "codetour: usage: :TourDelete <name>"
    return
  end
  M.ensure_loaded()

  local exists = false
  for _, existing in ipairs(storage.list_tours()) do
    if existing == name then
      exists = true
      break
    end
  end
  if not exists then
    log.warn(string.format("codetour: tour '%s' not found", name))
    return
  end

  local choice = vim.fn.confirm(string.format("codetour: delete tour '%s'?", name), "&Yes\n&No", 2)
  if choice ~= 1 then
    return
  end

  if M.data.active_tour == name then
    reset_in_memory()
    storage.write_active(nil)
    local qf = require "codetour.qf"
    qf.update_if_tour_active(M.data.stops)
  end

  if storage.delete(name) then
    log.info(string.format("codetour: deleted tour '%s'", name))
  else
    log.error(string.format("codetour: failed to delete tour '%s'", name))
  end
end

---Add a stop at the cursor to the active tour. Auto-creates a "default" tour
---if none is active, so the very first :TourAdd "just works."
---@param note string?
function M.add(note)
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    log.warn "codetour: current buffer has no file"
    return
  end
  M.ensure_loaded()

  -- Auto-create "default" tour for friction-free first use.
  if M.data.active_tour == nil then
    M.data.active_tour = "default"
    storage.save("default", {}) -- materialize the file so :TourSelect can find it later
    storage.write_active "default"
  end

  -- Refresh first so the dedupe check uses current extmark positions, not
  -- possibly-stale stored lnums (e.g. after editing in this session).
  local anchor = require "codetour.anchor"
  anchor.refresh(M.data.stops)

  local cursor = vim.api.nvim_win_get_cursor(0)
  local lnum, col = cursor[1], cursor[2]

  -- Idempotent dedupe: refuse to create two stops at the same (file, lnum).
  local util = require "codetour.util"
  local target_file = util.canonical(file)
  for _, existing in ipairs(M.data.stops) do
    if util.canonical(existing.file) == target_file and existing.lnum == lnum then
      log.warn(string.format("codetour: a stop already exists at %s:%d", vim.fn.fnamemodify(file, ":t"), lnum))
      return
    end
  end

  local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
  table.insert(M.data.stops, {
    file = file,
    lnum = lnum,
    col = col,
    note = note or "",
    context = util.trim_context(line),
  })

  anchor.attach(0, M.data.stops)
  local notes = require "codetour.notes"
  notes.refresh_all(M.data.stops, M.data.active_tour)
  local signs = require "codetour.signs"
  signs.refresh_all(M.data.stops)
  local qf = require "codetour.qf"
  qf.update_if_tour_active(M.data.stops)
  save()
  log.info(string.format("codetour: stop #%d added at %s:%d", #M.data.stops, vim.fn.fnamemodify(file, ":t"), lnum))
end

---Find the index of the stop in `stops` nearest the cursor in the current buffer.
---Same-line preferred; otherwise nearest by line distance, current file only.
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

---Replace the note of the stop nearest the cursor.
---@param text string
function M.edit_note(text)
  if text == nil or text == "" then
    log.warn "codetour: usage: :TourNoteEdit <new text>"
    return
  end
  M.ensure_loaded()
  if not require_active() then
    return
  end

  local idx = nearest_stop_idx_in_buf(M.data.stops)
  if idx == nil then
    log.warn "codetour: no stop in current buffer"
    return
  end

  M.data.stops[idx].note = text
  local notes = require "codetour.notes"
  notes.refresh(0, M.data.stops, M.data.active_tour)
  -- signs don't depend on note text, so no signs.refresh needed here
  local qf = require "codetour.qf"
  qf.update_if_tour_active(M.data.stops)
  save()
  log.info(string.format("codetour: stop #%d note updated", idx))
end

---Remove the stop nearest the cursor. Re-keys extmarks across all loaded
---buffers so subsequent index references stay valid.
function M.remove()
  M.ensure_loaded()
  if not require_active() then
    return
  end

  local idx = nearest_stop_idx_in_buf(M.data.stops)
  if idx == nil then
    log.warn "codetour: no stop in current buffer"
    return
  end

  local anchor = require "codetour.anchor"
  anchor.refresh(M.data.stops)

  local removed = M.data.stops[idx]
  local removed_label = string.format("%s:%d", vim.fn.fnamemodify(removed.file, ":t"), removed.lnum)
  table.remove(M.data.stops, idx)

  -- Indices shifted; rebuild extmark/note/sign tracking from scratch.
  local notes = require "codetour.notes"
  local signs = require "codetour.signs"
  anchor.detach_all()
  notes.detach_all()
  signs.detach_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      anchor.attach(bufnr, M.data.stops)
      notes.refresh(bufnr, M.data.stops, M.data.active_tour)
      signs.refresh(bufnr, M.data.stops)
    end
  end

  local qf = require "codetour.qf"
  qf.update_if_tour_active(M.data.stops)

  save()
  log.info(string.format("codetour: stop #%d removed (%s); %d stops remaining", idx, removed_label, #M.data.stops))
end

function M.dump()
  M.ensure_loaded()
  print(vim.inspect {
    active_tour = M.data.active_tour,
    stops = M.data.stops,
    available_tours = storage.list_tours(),
  })
end

---Find the stop in the current buffer with the smallest lnum strictly above
---(or below) the cursor. Sort is by lnum, NOT by stop index — so "next" is
---the next stop *down the file*, regardless of whether it's stop #1 or #5.
---@param stops CodeTour.Stop[]
---@param direction "next"|"prev"
---@return CodeTour.Stop?
local function adjacent_stop_in_buf(stops, direction)
  local util = require "codetour.util"
  local current_path = util.canonical(vim.api.nvim_buf_get_name(0))
  if current_path == nil then
    return nil
  end

  local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]

  local in_buf = {}
  for _, stop in ipairs(stops) do
    if util.canonical(stop.file) == current_path then
      table.insert(in_buf, stop)
    end
  end
  if #in_buf == 0 then
    return nil
  end

  table.sort(in_buf, function(a, b)
    return (a.lnum or 1) < (b.lnum or 1)
  end)

  if direction == "next" then
    for _, stop in ipairs(in_buf) do
      if (stop.lnum or 1) > cursor_lnum then
        return stop
      end
    end
  else -- "prev"
    for i = #in_buf, 1, -1 do
      if (in_buf[i].lnum or 1) < cursor_lnum then
        return in_buf[i]
      end
    end
  end
  return nil
end

---Atomic "swap the entire stops list" — used by :TourEdit's apply path.
---Drops every extmark / note / sign, replaces stops, re-attaches across
---all loaded buffers, syncs qf, and saves. The caller is expected to have
---already validated the new list (e.g. via edit.parse + edit.apply).
---@param new_stops CodeTour.Stop[]
function M.replace_stops(new_stops)
  M.ensure_loaded()
  if M.data.active_tour == nil then
    log.warn "codetour: no active tour to replace stops in"
    return
  end

  local anchor = require "codetour.anchor"
  local notes = require "codetour.notes"
  local signs = require "codetour.signs"
  anchor.detach_all()
  notes.detach_all()
  signs.detach_all()

  M.data.stops = new_stops

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      anchor.attach(bufnr, M.data.stops)
      notes.refresh(bufnr, M.data.stops, M.data.active_tour)
      signs.refresh(bufnr, M.data.stops)
    end
  end

  local qf = require "codetour.qf"
  qf.update_if_tour_active(M.data.stops)

  save()
  log.info(string.format("codetour: tour updated (%d stops)", #M.data.stops))
end

---Move cursor to the next stop *in the current buffer*, sorted by line
---number ascending. Reports an error when there is no stop further down
---(matches vim's E553 "No more items" idiom for :cnext at the end of qf).
---Pure cursor movement: no qf changes, no state mutation, no save.
function M.next_stop_in_buf()
  M.ensure_loaded()
  local stop = adjacent_stop_in_buf(M.data.stops, "next")
  if stop == nil then
    log.error "codetour: no next stop in this buffer"
    return
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { stop.lnum or 1, stop.col or 0 })
  vim.cmd "normal! zz"
end

---Move cursor to the previous stop *in the current buffer*, sorted by line
---number ascending. Reports an error when there is no stop further up.
---Pure cursor movement.
function M.prev_stop_in_buf()
  M.ensure_loaded()
  local stop = adjacent_stop_in_buf(M.data.stops, "prev")
  if stop == nil then
    log.error "codetour: no previous stop in this buffer"
    return
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { stop.lnum or 1, stop.col or 0 })
  vim.cmd "normal! zz"
end

---@return string[] tour names available in storage
function M.list_tours()
  M.ensure_loaded()
  return storage.list_tours()
end

---Like list_tours() but enriched with stop counts and active-marker.
---Used by the tour picker. One file read per tour — fine for the small N
---we expect (typically <10 tours per repo).
---@return { name: string, stops_count: integer, is_active: boolean }[]
function M.tours_with_meta()
  M.ensure_loaded()
  local out = {}
  for _, name in ipairs(storage.list_tours()) do
    local loaded = storage.load(name)
    table.insert(out, {
      name = name,
      stops_count = loaded and #loaded.stops or 0,
      is_active = M.data.active_tour == name,
    })
  end
  return out
end

return M
