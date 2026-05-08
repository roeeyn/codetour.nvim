local M = {}

M._opts = {
  default_keymaps = false,
  close_qf_on_tour_close = false, -- if true, :TourClose runs :cclose; otherwise leaves the qf window alone
}

M._state = {
  path_name = nil, -- string when a path is active, nil otherwise
  stops = {}, -- list of { file, lnum, col, note }
  qf_backup = nil, -- snapshot of prior quickfix, set by open(), cleared by close()
  loaded = false, -- whether we've attempted to load from disk for the current branch
}

local STORAGE_VERSION = 1

-- Returns { root, branch, file } if the cwd is inside a git repo, otherwise nil.
-- `file` is the absolute path to this branch's persistence file.
local function git_info()
  local root = vim.fn.system "git rev-parse --show-toplevel 2>/dev/null"
  root = (root or ""):gsub("%s+$", "")
  if vim.v.shell_error ~= 0 or root == "" then
    return nil
  end

  local branch = vim.fn.system "git symbolic-ref --short HEAD 2>/dev/null"
  branch = (branch or ""):gsub("%s+$", "")
  if vim.v.shell_error ~= 0 or branch == "" then
    branch = "no-branch"
  end

  local safe_branch = branch:gsub("/", "_")
  return {
    root = root,
    branch = branch,
    file = root .. "/.git/info/codetour/" .. safe_branch .. ".json",
  }
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

local function save()
  local info = git_info()
  if info == nil then
    return -- not in a repo; persistence disabled silently
  end

  local stops_relative = {}
  for _, s in ipairs(M._state.stops) do
    table.insert(stops_relative, {
      file = to_relative(s.file, info.root),
      lnum = s.lnum,
      col = s.col,
      note = s.note,
    })
  end

  local payload = {
    version = STORAGE_VERSION,
    active = M._state.path_name or "default",
    paths = {
      {
        name = M._state.path_name or "default",
        stops = stops_relative,
      },
    },
  }

  local encoded = vim.fn.json_encode(payload)
  if not write_file(info.file, encoded) then
    vim.notify("codetour: failed to write " .. info.file, vim.log.levels.ERROR)
  end
end

-- Load state from disk on first access. Cheap no-op on subsequent calls.
local function ensure_loaded()
  if M._state.loaded then
    return
  end
  M._state.loaded = true -- mark first to avoid re-entrancy on errors

  local info = git_info()
  if info == nil then
    return
  end

  local content = read_file(info.file)
  if content == nil then
    return -- no file yet; empty in-memory state is correct
  end

  local ok, decoded = pcall(vim.fn.json_decode, content)
  if not ok or type(decoded) ~= "table" then
    vim.notify("codetour: failed to parse " .. info.file, vim.log.levels.WARN)
    return
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
    return
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

  M._state.path_name = active_path.name
  M._state.stops = restored
end

local function snapshot_qf()
  local prev = vim.fn.getqflist { items = 1, title = 1 }
  return {
    items = prev.items or {},
    title = prev.title or "",
  }
end

function M.setup(opts)
  M._opts = vim.tbl_deep_extend("force", M._opts, opts or {})
end

function M.ping()
  vim.notify("codetour: pong", vim.log.levels.INFO)
end

function M.start(name)
  M._state.path_name = name or "default"
  M._state.stops = {}
  M._state.loaded = true -- explicitly initialized; no need to read from disk
  save()
  vim.notify(string.format("codetour: started path '%s'", M._state.path_name), vim.log.levels.INFO)
end

function M.add(note)
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    vim.notify("codetour: current buffer has no file", vim.log.levels.WARN)
    return
  end
  ensure_loaded()
  if M._state.path_name == nil then
    M._state.path_name = "default"
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local lnum, col = cursor[1], cursor[2]
  table.insert(M._state.stops, {
    file = file,
    lnum = lnum,
    col = col,
    note = note or "",
  })
  save()
  vim.notify(
    string.format("codetour: stop #%d added at %s:%d", #M._state.stops, vim.fn.fnamemodify(file, ":t"), lnum),
    vim.log.levels.INFO
  )
end

function M.dump()
  ensure_loaded()
  print(vim.inspect(M._state))
end

function M.open()
  ensure_loaded()
  if #M._state.stops == 0 then
    vim.notify("codetour: no stops to open", vim.log.levels.WARN)
    return
  end

  -- Only snapshot the prior qf if we're not already in a tour.
  -- This makes :TourOpen idempotent: re-running it refreshes without losing the real prior list.
  local current_title = (vim.fn.getqflist { title = 1 } or {}).title or ""
  if not current_title:match "^tour:" then
    M._state.qf_backup = snapshot_qf()
  end

  local items = {}
  for _, stop in ipairs(M._state.stops) do
    table.insert(items, {
      filename = stop.file,
      lnum = stop.lnum,
      col = stop.col + 1, -- qf wants 1-indexed col; we store 0-indexed
      text = stop.note ~= "" and stop.note or "(no note)",
    })
  end

  local info = git_info()
  local title = string.format("tour:%s", info and info.branch or "no-branch")
  vim.fn.setqflist({}, " ", { title = title, items = items })

  vim.cmd "cfirst"
  vim.cmd "cwindow"
end

function M.close()
  local backup = M._state.qf_backup

  if backup == nil then
    vim.fn.setqflist({}, "r", { items = {}, title = "" })
  else
    vim.fn.setqflist({}, "r", {
      items = backup.items,
      title = backup.title,
    })
    M._state.qf_backup = nil
  end

  if M._opts.close_qf_on_tour_close then
    vim.cmd "cclose"
  end
end

return M
