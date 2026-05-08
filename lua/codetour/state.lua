local storage = require "codetour.storage"
local M = {}

M.data = {
  path_name = nil, -- string when a path is active, nil otherwise
  stops = {}, -- list of { file, lnum, col, note }
  loaded = false, -- whether we've attempted to load from disk
}

local function save()
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

function M.start(name)
  M.data.path_name = name or "default"
  M.data.stops = {}
  M.data.loaded = true -- explicitly initialized; no need to read from disk
  save()
  vim.notify(string.format("codetour: started path '%s'", M.data.path_name), vim.log.levels.INFO)
end

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
  table.insert(M.data.stops, {
    file = file,
    lnum = lnum,
    col = col,
    note = note or "",
  })
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
