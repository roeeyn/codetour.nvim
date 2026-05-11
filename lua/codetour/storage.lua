local git = require "codetour.git"
local Tour = require "codetour.tour"
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

---Resolve the configured tour directory.
---Relative `storage_path` joins to the git root (returns nil if not in a repo).
---Absolute `storage_path` is used as-is (allows tours outside any repo).
---@param info CodeTour.GitInfo? May be nil when not in a git repo
---@return string?
local function tour_dir(info)
  local config = require "codetour.config"
  local sub = config.opts.storage_path or ".codetour"

  if sub:sub(1, 1) == "/" or sub:sub(1, 1) == "~" then
    return vim.fn.expand(sub)
  end

  if info == nil then
    return nil -- relative path requires a git root
  end
  return info.root .. "/" .. sub
end

local function tour_file(info, name)
  local dir = tour_dir(info)
  if dir == nil then
    return nil
  end
  -- Sanitize: replace path-unsafe chars with `_`
  local safe = name:gsub("[/\\:]", "_")
  return dir .. "/" .. safe .. ".json"
end

local function active_file_path(info)
  local dir = tour_dir(info)
  if dir == nil then
    return nil
  end
  return dir .. "/" .. ACTIVE_FILE
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
  local dir = tour_dir(info)
  if dir == nil or vim.fn.isdirectory(dir) == 0 then
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

---Load a tour by name from disk.
---@param name string
---@return CodeTour.Tour? nil if not found, parse error, or invalid
function M.load_tour(name)
  if name == nil or name == "" then
    return nil
  end
  local info = git.info()
  local file = tour_file(info, name)
  if file == nil then
    return nil -- relative storage_path + no git repo
  end
  local content = read_file(file)
  if content == nil then
    return nil
  end

  local ok, decoded = pcall(vim.fn.json_decode, content)
  if not ok or type(decoded) ~= "table" then
    require("codetour.log").warn("codetour: failed to parse " .. file)
    return nil
  end

  local tour = Tour.new(decoded.name or name)
  tour.next_id = decoded.next_id or 1
  local root = info and info.root or nil
  for _, s in ipairs(decoded.stops or {}) do
    table.insert(tour.stops, {
      id = s.id, -- may be nil for legacy tour files — synthesised below
      file = to_absolute(s.file, root),
      lnum = s.lnum,
      col = s.col,
      note = s.note or "",
      context = s.context or "",
    })
  end

  -- Backward-compat: legacy tour files predate stop.id. Walk the stops and
  -- assign sequential ids to any that lack one, advancing tour.next_id past
  -- the highest existing id so future add_stop cannot collide.
  local max_id = 0
  for _, s in ipairs(tour.stops) do
    if s.id and s.id > max_id then
      max_id = s.id
    end
  end
  if max_id >= tour.next_id then
    tour.next_id = max_id + 1
  end
  for _, s in ipairs(tour.stops) do
    if s.id == nil then
      s.id = tour.next_id
      tour.next_id = tour.next_id + 1
    end
  end

  return tour
end

---Save a tour to its file.
---@param tour CodeTour.Tour
function M.save_tour(tour)
  if tour == nil or tour.name == nil or tour.name == "" then
    return
  end
  local info = git.info()
  local file = tour_file(info, tour.name)
  if file == nil then
    warn_no_repo_once()
    return -- relative storage_path + no git repo; persistence disabled
  end

  -- Stop file paths still relativize against git root when one exists, so
  -- that tours remain portable across clones. Without a git root they stay
  -- absolute (the to_relative helper handles a nil root by passthrough).
  local root = info and info.root or nil
  local stops_rel = {}
  for _, s in ipairs(tour.stops) do
    table.insert(stops_rel, {
      id = s.id,
      file = to_relative(s.file, root),
      lnum = s.lnum,
      col = s.col,
      note = s.note,
      context = s.context or "",
    })
  end

  local payload = {
    version = STORAGE_VERSION,
    name = tour.name,
    next_id = tour.next_id,
    stops = stops_rel,
  }

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
  local file = tour_file(info, name)
  if file == nil then
    return false
  end
  return vim.fn.delete(file) == 0
end

---Read the name of the last-active tour, or nil.
---@return string?
function M.read_active()
  local info = git.info()
  local file = active_file_path(info)
  if file == nil then
    return nil
  end
  local content = read_file(file)
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
  local file = active_file_path(info)
  if file == nil then
    return
  end
  if name == nil or name == "" then
    vim.fn.delete(file)
    return
  end
  write_file(file, name .. "\n")
end

return M
