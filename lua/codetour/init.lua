local config = require "codetour.config"
local state = require "codetour.state"
local qf = require "codetour.qf"

local M = {}

---@param opts CodeTour.Opts? User-supplied overrides; merged on top of defaults
function M.setup(opts)
  config.merge(opts)
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
