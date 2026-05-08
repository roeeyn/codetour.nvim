local config = require "codetour.config"
local state = require "codetour.state"
local qf = require "codetour.qf"

local M = {}

function M.setup(opts)
  config.merge(opts)
end

function M.ping()
  vim.notify("codetour: pong", vim.log.levels.INFO)
end

function M.start(name)
  state.start(name)
end

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
