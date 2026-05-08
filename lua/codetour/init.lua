local config = require "codetour.config"
local state = require "codetour.state"
local qf = require "codetour.qf"

local M = {}

---@param opts CodeTour.Opts? User-supplied overrides; merged on top of defaults
function M.setup(opts)
  config.merge(opts)

  -- Re-apply the highlight link in case the user changed `note_highlight`. The
  -- plugin/ shim already set a default at startup; this lets setup() override it.
  vim.api.nvim_set_hl(0, "CodetourNote", { link = config.opts.note_highlight, default = true })

  -- Cover the case where this plugin loads after some buffers were already read
  -- (e.g. lazy.nvim's default deferred loading): walk loaded buffers and attach
  -- extmarks/notes for the active tour's stops.
  local anchor = require "codetour.anchor"
  local notes = require "codetour.notes"
  state.ensure_loaded()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      anchor.attach(bufnr, state.data.stops)
      notes.refresh(bufnr, state.data.stops, state.data.active_tour)
    end
  end
end

function M.ping()
  vim.notify("codetour: pong", vim.log.levels.INFO)
end

---@param name string? Tour name (required)
function M.create(name)
  state.create(name)
end

---@param name string? Tour name to switch to (required)
function M.select(name)
  state.select(name)
end

---@param name string? Tour name to delete (required)
function M.delete(name)
  state.delete(name)
end

---@return string[] tour names available in storage
function M.list_tours()
  return state.list_tours()
end

---Open a picker over the active tour's stops. Default action: jump to the stop.
function M.list()
  require("codetour.picker").stops()
end

---Open a picker over available tours. Default action: switch to that tour.
function M.pick_tour()
  require("codetour.picker").tours()
end

---@param note string? Optional note describing why this stop matters
function M.add(note)
  state.add(note)
end

function M.remove()
  state.remove()
end

function M.dump()
  state.dump()
end

---@param text string New note text for the stop nearest the cursor
function M.edit_note(text)
  state.edit_note(text)
end

function M.toggle_notes()
  local notes = require "codetour.notes"
  local visible = notes.toggle(state.data.stops, state.data.active_tour)
  vim.notify("codetour: notes " .. (visible and "shown" or "hidden"), vim.log.levels.INFO)
end

function M.open()
  qf.open()
end

function M.close()
  qf.close()
end

return M
