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
  -- Drop every extmark before clearing the stop list so the buffer
  -- isn't left with orphan markers pointing at indexes that no longer exist.
  local anchor = require "codetour.anchor"
  anchor.detach_all()
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
  if M.data.path_name == nil then
    M.data.path_name = "default"
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local lnum, col = cursor[1], cursor[2]
  local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
  local util = require "codetour.util"
  table.insert(M.data.stops, {
    file = file,
    lnum = lnum,
    col = col,
    note = note or "",
    context = util.trim_context(line),
  })
  -- Attach an extmark to the just-added stop so future edits track its position.
  local anchor = require "codetour.anchor"
  anchor.attach(0, M.data.stops)
  save()
  vim.notify(
    string.format("codetour: stop #%d added at %s:%d", #M.data.stops, vim.fn.fnamemodify(file, ":t"), lnum),
    vim.log.levels.INFO
  )
end

function M.dump()
  M.ensure_loaded()
  print(vim.inspect(M.data))
end

return M
