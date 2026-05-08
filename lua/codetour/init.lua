local config = require "codetour.config"
local state = require "codetour.state"
local qf = require "codetour.qf"

local M = {}

---@param opts CodeTour.Opts? User-supplied overrides; merged on top of defaults
function M.setup(opts)
  config.merge(opts)

  -- Cover the case where this plugin loads after some buffers were already read
  -- (e.g. lazy.nvim's default deferred loading): walk the loaded buffers and
  -- attach extmarks for any matching stops.
  local anchor = require "codetour.anchor"
  state.ensure_loaded()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      anchor.attach(bufnr, state.data.stops)
    end
  end
end

function M.ping()
  vim.notify("codetour: pong", vim.log.levels.INFO)
end

---@param name string? Optional path name; defaults to "default"
function M.start(name)
  state.start(name)
end

---@param note string? Optional note describing why this stop matters
function M.add(note)
  state.add(note)
end

function M.dump()
  state.dump()
end

function M.open()
  qf.open()
end

function M.close()
  qf.close()
end

return M
