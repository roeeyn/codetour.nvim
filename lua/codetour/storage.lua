local git = require "codetour.git"
local M = {}

local STORAGE_VERSION = 1

local function to_relative(file, root)
  if root and file:sub(1, #root + 1) == root .. "/" then
    return file:sub(#root + 2)
  end
  return file -- absolute path preserved as fallback (file outside the repo)
end

local function to_absolute(file, root)
  if root and not file:match "^/" then
    return root .. "/" .. file
  end
  return file
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read "*a"
  f:close()
  return content
end

local function write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "w")
  if not f then
    return false
  end
  f:write(content)
  f:close()
  return true
end

function M.save(path_name, stops)
  local info = git.info()
  if info == nil then
    return -- not in a repo; persistence disabled silently
  end

  local stops_rel = {}
  for _, s in ipairs(stops) do
    table.insert(stops_rel, {
      file = to_relative(s.file, info.root),
      lnum = s.lnum,
      col = s.col,
      note = s.note,
    })
  end

  local payload = {
    version = STORAGE_VERSION,
    active = path_name or "default",
    paths = {
      { name = path_name or "default", stops = stops_rel },
    },
  }

  local encoded = vim.fn.json_encode(payload)
  if not write_file(info.file, encoded) then
    vim.notify("codetour: failed to write " .. info.file, vim.log.levels.ERROR)
  end
end

function M.load()
  local info = git.info()
  if info == nil then
    return nil
  end

  local content = read_file(info.file)
  if content == nil then
    return nil -- no file yet
  end

  local ok, decoded = pcall(vim.fn.json_decode, content)
  if not ok or type(decoded) ~= "table" then
    vim.notify("codetour: failed to parse " .. info.file, vim.log.levels.WARN)
    return nil
  end

  local active_name = decoded.active or "default"
  local active_path
  for _, p in ipairs(decoded.paths or {}) do
    if p.name == active_name then
      active_path = p
      break
    end
  end
  if active_path == nil then
    return nil
  end

  local restored = {}
  for _, s in ipairs(active_path.stops or {}) do
    table.insert(restored, {
      file = to_absolute(s.file, info.root),
      lnum = s.lnum,
      col = s.col,
      note = s.note or "",
    })
  end

  return { path_name = active_path.name, stops = restored }
end

return M
