local storage = require "codetour.storage"
local Tour = require "codetour.tour"
local decoration = require "codetour.decoration"
local log = require "codetour.log"
local M = {}

---@class CodeTour.Stop
---@field id integer Stable identity within the Tour; assigned by Tour.add_stop, never reused
---@field file string Canonical absolute path to the file the stop lives in
---@field lnum integer 1-indexed line number (matches nvim_win_get_cursor)
---@field col integer 0-indexed byte column (matches nvim_win_get_cursor)
---@field note string User's prose for this stop; empty string if no note was given
---@field context string Trimmed snippet (~60 chars) of the line content; used for cold-load re-anchor

---@class CodeTour.State
---@field active_tour CodeTour.Tour? The one tour currently in memory; nil = none active
---@field loaded boolean Whether ensure_loaded() has run

---@type CodeTour.State
M.data = {
  active_tour = nil,
  loaded = false,
}

---Stops of the active tour, or an empty list if no tour is active.
---Convenience for callers (anchor, notes, signs, qf) that want to iterate
---without first nil-checking the active tour.
---@return CodeTour.Stop[]
function M.stops()
  if M.data.active_tour == nil then
    return {}
  end
  return M.data.active_tour.stops
end

---Run offline drift detection against every stop in `tour` whose file is
---not currently loaded as a buffer. Files that ARE loaded already have an
---authoritative position via anchor.attach on BufRead, so we skip those
---(both to avoid redundant disk reads and to avoid overwriting an in-buf
---extmark position with a stale persisted value).
---@param tour CodeTour.Tour
local function detect_offline_drift(tour)
  local util = require "codetour.util"
  local loaded_paths = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local p = util.canonical(vim.api.nvim_buf_get_name(bufnr))
      if p then
        loaded_paths[p] = true
      end
    end
  end
  local anchor = require "codetour.anchor"
  for _, stop in ipairs(tour.stops) do
    if not loaded_paths[util.canonical(stop.file) or stop.file] then
      anchor.detect_drift_offline(stop)
    end
  end
end

local function save()
  if M.data.active_tour == nil then
    return
  end
  decoration.sync_positions(M.data.active_tour.stops)
  storage.save_tour(M.data.active_tour)
end

---Load the last-active tour (if any) on first call. Cheap no-op afterwards.
---If the active-pointer references a missing/corrupt tour, clears the pointer
---and notifies — the user isn't stuck with a phantom active tour.
function M.ensure_loaded()
  if M.data.loaded then
    return
  end
  M.data.loaded = true

  local active_name = storage.read_active()
  if active_name == nil then
    return
  end

  local tour = storage.load_tour(active_name)
  if tour == nil then
    log.warn(string.format("codetour: active tour '%s' couldn't be loaded; clearing active pointer", active_name))
    storage.write_active(nil)
    return
  end

  detect_offline_drift(tour)
  M.data.active_tour = tour
end

local function require_active()
  if M.data.active_tour == nil then
    log.warn "codetour: no active tour. Use :TourCreate <name> or :TourSelect <name> first."
    return false
  end
  return true
end

---Drop all buffer decoration and reset in-memory state.
local function reset_in_memory()
  decoration.detach_all()
  M.data.active_tour = nil
end

---Re-render decoration across all loaded buffers, then sync qf.
local function rehydrate_all_buffers()
  decoration.refresh_all(M.data.active_tour)
  local qf = require "codetour.qf"
  qf.update_if_tour_active(M.stops())
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
  M.data.active_tour = Tour.new(name)
  storage.save_tour(M.data.active_tour)
  storage.write_active(name)

  -- No stops to render yet, but sync qf in case a tour view was active.
  local qf = require "codetour.qf"
  qf.update_if_tour_active(M.data.active_tour.stops)

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

  local tour = storage.load_tour(name)
  if tour == nil then
    log.warn(string.format("codetour: tour '%s' not found", name))
    return
  end

  reset_in_memory()
  detect_offline_drift(tour)
  M.data.active_tour = tour
  storage.write_active(name)
  rehydrate_all_buffers()

  log.info(string.format("codetour: selected tour '%s' (%d stops)", name, #M.data.active_tour.stops))
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

  if M.data.active_tour and M.data.active_tour.name == name then
    reset_in_memory()
    storage.write_active(nil)
    local qf = require "codetour.qf"
    qf.update_if_tour_active {}
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
    M.data.active_tour = Tour.new "default"
    storage.save_tour(M.data.active_tour) -- materialize the file so :TourSelect can find it later
    storage.write_active "default"
  end

  -- Refresh first so the dedupe check uses current extmark positions, not
  -- possibly-stale stored lnums (e.g. after editing in this session).
  decoration.sync_positions(M.data.active_tour.stops)

  local cursor = vim.api.nvim_win_get_cursor(0)
  local lnum, col = cursor[1], cursor[2]
  local util = require "codetour.util"
  -- Canonicalise the file path at insert time so Tour's dedupe (plain string
  -- equality) handles macOS /tmp vs /private/tmp and other symlink resolution
  -- correctly. The invariant from here on: every stop in a Tour has a
  -- canonical absolute path.
  local canonical_file = util.canonical(file) or file

  local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
  local stop = {
    file = canonical_file,
    lnum = lnum,
    col = col,
    note = note or "",
    context = util.trim_context(line),
  }

  local ok, err = Tour.add_stop(M.data.active_tour, stop)
  if not ok then
    log.warn(string.format("codetour: %s", err))
    return
  end

  -- Adding a stop shifts (idx/total) for every existing stop's note + sign
  -- (visible text depends on array position), so we still re-render across
  -- every loaded buffer. Anchor extmarks are reused via stop.id keying.
  decoration.refresh_all(M.data.active_tour)
  local qf = require "codetour.qf"
  qf.update_if_tour_active(M.data.active_tour.stops)
  save()
  log.info(
    string.format("codetour: stop #%d added at %s:%d", #M.data.active_tour.stops, vim.fn.fnamemodify(file, ":t"), lnum)
  )
end

---Resolve the current buffer's canonical path, or nil if there isn't one.
---@return string?
local function current_canonical_path()
  local util = require "codetour.util"
  return util.canonical(vim.api.nvim_buf_get_name(0))
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

  local current_path = current_canonical_path()
  if current_path == nil then
    log.warn "codetour: no stop in current buffer"
    return
  end
  local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
  local idx = Tour.nearest_stop_idx(M.data.active_tour, current_path, cursor_lnum)
  if idx == nil then
    log.warn "codetour: no stop in current buffer"
    return
  end

  local ok, err = Tour.update_note(M.data.active_tour, idx, text)
  if not ok then
    log.warn(string.format("codetour: %s", err))
    return
  end

  -- Only the note text changed for one stop. Re-render decoration for the
  -- current buffer so that note shows the new text. Signs are unaffected
  -- (sign_text depends on idx, not note), but the cost of going through
  -- the facade is the same and keeps state.lua free of fan-out trios.
  decoration.attach_buffer(0, M.data.active_tour)
  local qf = require "codetour.qf"
  qf.update_if_tour_active(M.data.active_tour.stops)
  save()
  log.info(string.format("codetour: stop #%d note updated", idx))
end

---Remove the stop nearest the cursor.
function M.remove()
  M.ensure_loaded()
  if not require_active() then
    return
  end

  local current_path = current_canonical_path()
  if current_path == nil then
    log.warn "codetour: no stop in current buffer"
    return
  end
  local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
  local idx = Tour.nearest_stop_idx(M.data.active_tour, current_path, cursor_lnum)
  if idx == nil then
    log.warn "codetour: no stop in current buffer"
    return
  end

  -- Pull live extmark positions into the stops first so the save reflects
  -- where the line actually is, not the persisted lnum from add-time.
  decoration.sync_positions(M.data.active_tour.stops)

  local removed = Tour.remove_stop(M.data.active_tour, idx)
  local removed_label = string.format("%s:%d", vim.fn.fnamemodify(removed.file, ":t"), removed.lnum)

  -- Drop the removed stop's extmark/note/sign directly. The remaining stops
  -- keep their anchor extmarks (id-keyed, no shift) but their note/sign text
  -- needs re-rendering because (idx/total) shifted; refresh_all covers that.
  decoration.detach_stop(removed.id)
  decoration.refresh_all(M.data.active_tour)

  local qf = require "codetour.qf"
  qf.update_if_tour_active(M.data.active_tour.stops)

  save()
  log.info(
    string.format("codetour: stop #%d removed (%s); %d stops remaining", idx, removed_label, #M.data.active_tour.stops)
  )
end

function M.dump()
  M.ensure_loaded()
  print(vim.inspect {
    active_tour = M.data.active_tour,
    available_tours = storage.list_tours(),
  })
end

---Atomic "swap the entire stops list" — used by :CodeTour's apply path.
---Drops every extmark / note / sign, replaces stops, re-attaches across
---all loaded buffers, syncs qf, and saves. The caller is expected to have
---already validated that each new stop maps to an original (the idx-existence
---check from edit.lua); Tour.replace_stops adds the (file,lnum)-duplicate check.
---@param new_stops CodeTour.Stop[]
function M.replace_stops(new_stops)
  M.ensure_loaded()
  if M.data.active_tour == nil then
    log.warn "codetour: no active tour to replace stops in"
    return
  end

  local ok, err = Tour.replace_stops(M.data.active_tour, new_stops)
  if not ok then
    log.warn(string.format("codetour: %s", err))
    return
  end

  -- :CodeTour can reorder, edit notes, and drop stops. Stops that survive
  -- the apply keep their ids — and therefore their anchor extmarks. Stops
  -- that were dropped leave orphan extmarks in the maps; detach_all clears
  -- those en masse rather than tracking each one. (refresh_all reattaches
  -- the survivors.)
  decoration.detach_all()
  decoration.refresh_all(M.data.active_tour)

  local qf = require "codetour.qf"
  qf.update_if_tour_active(M.data.active_tour.stops)

  save()
  log.info(string.format("codetour: tour updated (%d stops)", #M.data.active_tour.stops))
end

---Move cursor to the next stop *in the current buffer*, sorted by line
---number ascending. Reports an error when there is no stop further down
---(matches vim's E553 "No more items" idiom for :cnext at the end of qf).
---Pure cursor movement: no qf changes, no state mutation, no save.
function M.next_stop_in_buf()
  M.ensure_loaded()
  if M.data.active_tour == nil then
    log.error "codetour: no next stop in this buffer"
    return
  end
  local current_path = current_canonical_path()
  if current_path == nil then
    log.error "codetour: no next stop in this buffer"
    return
  end
  local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
  local stop = Tour.adjacent_stop(M.data.active_tour, current_path, cursor_lnum, "next")
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
  if M.data.active_tour == nil then
    log.error "codetour: no previous stop in this buffer"
    return
  end
  local current_path = current_canonical_path()
  if current_path == nil then
    log.error "codetour: no previous stop in this buffer"
    return
  end
  local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
  local stop = Tour.adjacent_stop(M.data.active_tour, current_path, cursor_lnum, "prev")
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
  local active_name = M.data.active_tour and M.data.active_tour.name or nil
  local out = {}
  for _, name in ipairs(storage.list_tours()) do
    local tour = storage.load_tour(name)
    table.insert(out, {
      name = name,
      stops_count = tour and #tour.stops or 0,
      is_active = active_name == name,
    })
  end
  return out
end

return M
