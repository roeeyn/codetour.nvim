local git = require "codetour.git"
local M = {}

local STORAGE_VERSION = 2
local ACTIVE_FILE = "_active_tour.txt"

-- Latched so the "not in a git repo" warning fires only once per session
-- rather than on every mutation attempt. Reset across nvim sessions.
local _warned_no_repo = false
local function warn_no_repo_once()
  if _warned_no_repo then
    return
  end
  _warned_no_repo = true
  require("codetour.log").warn "codetour: not inside a git repo — stops won't persist across sessions"
end

local function tour_dir(info)
  return info.root .. "/.git/info/codetour"
end

local function tour_file(info, name)
  -- Sanitize: replace path-unsafe chars with `_`
  local safe = name:gsub("[/\\:]", "_")
  return tour_dir(info) .. "/" .. safe .. ".json"
end

local function active_file_path(info)
  return tour_dir(info) .. "/" .. ACTIVE_FILE
end

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

---List the names of tours present in storage. Returns empty list if not in a repo.
---@return string[]
function M.list_tours()
  local info = git.info()
  if info == nil then
    return {}
  end
  local dir = tour_dir(info)
  if vim.fn.isdirectory(dir) == 0 then
    return {}
  end
  local out = {}
  for _, file in ipairs(vim.fn.glob(dir .. "/*.json", false, true)) do
    local name = vim.fn.fnamemodify(file, ":t:r")
    if name ~= "" and not name:match "^_" then
      table.insert(out, name)
    end
  end
  table.sort(out)
  return out
end

---Load a tour by name.
---@param name string
---@return { name: string, stops: CodeTour.Stop[] }? nil if not found, parse error, or invalid
function M.load(name)
  if name == nil or name == "" then
    return nil
  end
  local info = git.info()
  if info == nil then
    return nil
  end
  local file = tour_file(info, name)
  local content = read_file(file)
  if content == nil then
    return nil
  end

  local ok, decoded = pcall(vim.fn.json_decode, content)
  if not ok or type(decoded) ~= "table" then
    require("codetour.log").warn("codetour: failed to parse " .. file)
    return nil
  end

  local restored = {}
  for _, s in ipairs(decoded.stops or {}) do
    table.insert(restored, {
      file = to_absolute(s.file, info.root),
      lnum = s.lnum,
      col = s.col,
      note = s.note or "",
      context = s.context or "",
    })
  end

  return { name = decoded.name or name, stops = restored }
end

---Save a tour to its file.
---@param name string
---@param stops CodeTour.Stop[]
function M.save(name, stops)
  if name == nil or name == "" then
    return
  end
  local info = git.info()
  if info == nil then
    warn_no_repo_once()
    return -- not in a repo; persistence disabled
  end

  local stops_rel = {}
  for _, s in ipairs(stops) do
    table.insert(stops_rel, {
      file = to_relative(s.file, info.root),
      lnum = s.lnum,
      col = s.col,
      note = s.note,
      context = s.context or "",
    })
  end

  local payload = {
    version = STORAGE_VERSION,
    name = name,
    stops = stops_rel,
  }

  local file = tour_file(info, name)
  local encoded = vim.fn.json_encode(payload)
  if not write_file(file, encoded) then
    require("codetour.log").error("codetour: failed to write " .. file)
  end
end

---Delete a tour file by name.
---@param name string
---@return boolean success
function M.delete(name)
  if name == nil or name == "" then
    return false
  end
  local info = git.info()
  if info == nil then
    return false
  end
  local file = tour_file(info, name)
  return vim.fn.delete(file) == 0
end

---Read the name of the last-active tour, or nil.
---@return string?
function M.read_active()
  local info = git.info()
  if info == nil then
    return nil
  end
  local content = read_file(active_file_path(info))
  if content == nil then
    return nil
  end
  local trimmed = content:gsub("%s+$", "")
  if trimmed == "" then
    return nil
  end
  return trimmed
end

---Write (or clear) the active-tour pointer.
---@param name string?
function M.write_active(name)
  local info = git.info()
  if info == nil then
    return
  end
  local file = active_file_path(info)
  if name == nil or name == "" then
    vim.fn.delete(file)
    return
  end
  write_file(file, name .. "\n")
end

return M
