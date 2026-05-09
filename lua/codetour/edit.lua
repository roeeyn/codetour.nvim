local log = require "codetour.log"
local M = {}

---Tracks the open UI's resources so close() can tear them all down.
M._state = {
  list_winid = nil,
  list_bufnr = nil,
  preview_winid = nil,
  preview_bufnr = nil,
  prev_winid = nil, -- window the user was in before :TourEdit
  preview_cache = {}, -- [path] = scratch bufnr (reused as cursor moves between same-file stops)
  augroup = nil,
}

-- Format produced by render() and consumed by parse():
--   [N]  rel/path:lnum  ─  note text
-- N is the original stop index (identifier). file:lnum is display-only and
-- not parsed back into the stop. note text is editable.
local LINE_PATTERN = "^%[(%d+)%]%s+(.-):(%d+)%s+─%s*(.*)$"

---@class CodeTour.Edit.Parsed
---@field idx integer Original 1-based stop index in state.data.stops
---@field note string The (possibly-edited) note text

---Render the active tour's stops as buffer lines.
---@param stops CodeTour.Stop[]
---@return string[]
function M.render(stops)
  local lines = {}
  for idx, stop in ipairs(stops) do
    local rel = vim.fn.fnamemodify(stop.file, ":~:.")
    table.insert(lines, string.format("[%d]  %s:%d  ─  %s", idx, rel, stop.lnum or 1, stop.note or ""))
  end
  return lines
end

---Parse buffer lines into stop-edit records.
---Empty/whitespace-only lines are skipped. Any other malformed line aborts
---the parse with a human-readable error.
---@param buf_lines string[]
---@return CodeTour.Edit.Parsed[]?
---@return string? err_message
function M.parse(buf_lines)
  local parsed = {}
  for lineno, line in ipairs(buf_lines) do
    if line:match "^%s*$" or line:match "^%s*#" then
      -- skip blank and comment lines (the buffer's header uses `#` prefix)
    else
      local idx, _file, _lnum, note = line:match(LINE_PATTERN)
      if idx == nil then
        return nil, string.format("line %d: malformed entry: %s", lineno, line)
      end
      table.insert(parsed, { idx = tonumber(idx), note = note or "" })
    end
  end
  return parsed
end

---Apply a parsed buffer to the current tour. Atomic: either every line maps
---to a valid stop, or nothing changes.
---Returns (ok, err_message). On ok, state.replace_stops has been called and
---the fan-out (notes/signs/qf/save) is complete.
---@param parsed CodeTour.Edit.Parsed[]
---@return boolean ok
---@return string? err
function M.apply(parsed)
  local state = require "codetour.state"
  state.ensure_loaded()
  if state.data.active_tour == nil then
    return false, "no active tour"
  end

  local seen = {}
  local new_stops = {}
  for _, p in ipairs(parsed) do
    local original = state.data.stops[p.idx]
    if original == nil then
      return false, string.format("stop #%d doesn't exist in this tour", p.idx)
    end
    if seen[p.idx] then
      return false, string.format("stop #%d appears more than once", p.idx)
    end
    seen[p.idx] = true

    table.insert(new_stops, vim.tbl_extend("force", original, { note = p.note }))
  end

  state.replace_stops(new_stops)
  return true
end

---Convenience: parse + apply in one shot.
---@param buf_lines string[]
---@return boolean ok
---@return string? err
function M.commit(buf_lines)
  local parsed, perr = M.parse(buf_lines)
  if parsed == nil then
    return false, perr
  end
  return M.apply(parsed)
end

---Build the full list-buffer content: a few `#` header lines + the rendered stops.
---The header explains the keymaps and shows the active tour name + count.
---@param stops CodeTour.Stop[]
---@param tour_name string?
---@return string[]
function M._build_buffer_lines(stops, tour_name)
  local out = {
    string.format("# codetour ─ tour: %s  ·  %d stop(s)", tour_name or "default", #stops),
    "# <CR> jump   •   :w apply   •   q close",
    "",
  }
  for _, line in ipairs(M.render(stops)) do
    table.insert(out, line)
  end
  return out
end

---Find the buffer line number (1-based) of the first stop entry, skipping
---past the `#` header and any blank lines. Returns nil if no stops.
---@param buf_lines string[]
---@return integer?
function M._first_stop_lineno(buf_lines)
  for lineno, line in ipairs(buf_lines) do
    if line:match "^%[" then
      return lineno
    end
  end
  return nil
end

---Reset M._state and restore the previous window if it's still valid.
local function cleanup_state()
  if M._state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, M._state.augroup)
  end
  for _, b in pairs(M._state.preview_cache) do
    if vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  if M._state.prev_winid and vim.api.nvim_win_is_valid(M._state.prev_winid) then
    pcall(vim.api.nvim_set_current_win, M._state.prev_winid)
  end
  M._state = {
    list_winid = nil,
    list_bufnr = nil,
    preview_winid = nil,
    preview_bufnr = nil,
    prev_winid = nil,
    preview_cache = {},
    augroup = nil,
  }
end

---Build a scratch buffer holding the file's content with syntax highlighting.
---Pattern from oil.nvim: vim.filetype.match + treesitter, fall back to regex syntax.
---@param path string
---@return integer? bufnr
local function create_preview_scratch(path)
  local bufnr = vim.api.nvim_create_buf(false, true)
  if bufnr == 0 then
    return nil
  end
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false

  if vim.fn.filereadable(path) == 0 then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "[file not found: " .. path .. "]",
      "",
      "Edit/reorder/remove still works from the list buffer.",
    })
    vim.bo[bufnr].modifiable = false
    return bufnr
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "[error reading: " .. path .. "]" })
    vim.bo[bufnr].modifiable = false
    return bufnr
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  local ft = vim.filetype.match { filename = path, buf = bufnr }
  if ft and ft ~= "" then
    local started = false
    if vim.treesitter and vim.treesitter.language and vim.treesitter.language.get_lang then
      local lang = vim.treesitter.language.get_lang(ft)
      if lang then
        started = pcall(vim.treesitter.start, bufnr, lang)
      end
    end
    if not started then
      vim.bo[bufnr].syntax = ft
    end
  end

  vim.bo[bufnr].modifiable = false
  return bufnr
end

---Read [N] off the cursor's line, return matching stop or nil.
---@return integer? idx
---@return CodeTour.Stop?
local function stop_at_cursor()
  if not vim.api.nvim_win_is_valid(M._state.list_winid or -1) then
    return nil, nil
  end
  local lineno = vim.api.nvim_win_get_cursor(M._state.list_winid)[1]
  local line = vim.api.nvim_buf_get_lines(M._state.list_bufnr, lineno - 1, lineno, false)[1]
  if not line then
    return nil, nil
  end
  local idx = line:match "^%[(%d+)%]"
  if idx == nil then
    return nil, nil
  end
  idx = tonumber(idx)
  local state = require "codetour.state"
  return idx, state.data.stops[idx]
end

local function update_preview()
  if not vim.api.nvim_win_is_valid(M._state.preview_winid or -1) then
    return
  end
  local _, stop = stop_at_cursor()
  if stop == nil then
    return
  end

  local bufnr = M._state.preview_cache[stop.file]
  if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
    bufnr = create_preview_scratch(stop.file)
    if bufnr == nil then
      return
    end
    M._state.preview_cache[stop.file] = bufnr
  end

  vim.api.nvim_win_set_buf(M._state.preview_winid, bufnr)
  M._state.preview_bufnr = bufnr

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local target = math.min(stop.lnum or 1, math.max(line_count, 1))
  pcall(vim.api.nvim_win_set_cursor, M._state.preview_winid, { target, 0 })

  -- Center the highlighted line
  local saved_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(M._state.preview_winid) then
    vim.api.nvim_set_current_win(M._state.preview_winid)
    vim.cmd "normal! zz"
    if vim.api.nvim_win_is_valid(saved_win) then
      vim.api.nvim_set_current_win(saved_win)
    end
  end
end

---:w handler. Parse the buffer; on success, replace stops + re-render.
---On parse error, log + abort (buffer stays modified so user can fix).
local function on_save()
  local lines = vim.api.nvim_buf_get_lines(M._state.list_bufnr, 0, -1, false)
  local ok, err = M.commit(lines)
  if not ok then
    log.error("codetour: " .. (err or "unknown error"))
    return
  end
  local state = require "codetour.state"
  vim.api.nvim_buf_set_lines(
    M._state.list_bufnr,
    0,
    -1,
    false,
    M._build_buffer_lines(state.data.stops, state.data.active_tour)
  )
  vim.bo[M._state.list_bufnr].modified = false
  update_preview()
end

---<CR> handler. Refuses if list buffer has unsaved edits.
local function on_enter()
  if vim.bo[M._state.list_bufnr].modified then
    log.error "codetour: unsaved edits — :w to apply or :q! to discard"
    return
  end
  local _, stop = stop_at_cursor()
  if stop == nil then
    return
  end

  local target_winid = M._state.prev_winid
  local target_file = stop.file
  local target_lnum = stop.lnum or 1
  local target_col = stop.col or 0

  M.close()

  if target_winid and vim.api.nvim_win_is_valid(target_winid) then
    vim.api.nvim_set_current_win(target_winid)
  end
  vim.cmd("edit " .. vim.fn.fnameescape(target_file))
  pcall(vim.api.nvim_win_set_cursor, 0, { target_lnum, target_col })
  vim.cmd "normal! zz"
end

---Open the editable list buffer + preview pane for the active tour.
function M.open()
  local state = require "codetour.state"
  state.ensure_loaded()
  if state.data.active_tour == nil then
    log.error "codetour: no active tour. Use :TourCreate or :TourSelect first."
    return
  end

  -- If already open, focus the existing list window.
  if M._state.list_winid and vim.api.nvim_win_is_valid(M._state.list_winid) then
    vim.api.nvim_set_current_win(M._state.list_winid)
    return
  end

  M._state.prev_winid = vim.api.nvim_get_current_win()

  local list_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[list_bufnr].buftype = "acwrite" -- so :w fires BufWriteCmd
  vim.bo[list_bufnr].bufhidden = "wipe"
  vim.bo[list_bufnr].swapfile = false
  vim.bo[list_bufnr].filetype = "codetour"
  pcall(vim.api.nvim_buf_set_name, list_bufnr, "codetour://" .. state.data.active_tour)

  -- Header is written as `#` comment lines, which the parser skips. Putting
  -- the header inside the buffer (rather than via virt_lines_above) sidesteps
  -- nvim's "no display row above row 0" rendering quirk and lets the user
  -- copy/paste the help text out if they want.
  local lines = M._build_buffer_lines(state.data.stops, state.data.active_tour)
  vim.api.nvim_buf_set_lines(list_bufnr, 0, -1, false, lines)
  vim.bo[list_bufnr].modified = false

  vim.api.nvim_set_current_buf(list_bufnr)
  M._state.list_winid = vim.api.nvim_get_current_win()
  M._state.list_bufnr = list_bufnr

  vim.wo[M._state.list_winid].wrap = true
  vim.wo[M._state.list_winid].linebreak = true
  vim.wo[M._state.list_winid].breakindent = true
  vim.wo[M._state.list_winid].number = false
  vim.wo[M._state.list_winid].relativenumber = false
  vim.wo[M._state.list_winid].signcolumn = "no"
  vim.wo[M._state.list_winid].cursorline = true

  vim.cmd "rightbelow vsplit"
  M._state.preview_winid = vim.api.nvim_get_current_win()
  vim.wo[M._state.preview_winid].wrap = false
  vim.wo[M._state.preview_winid].number = true
  vim.wo[M._state.preview_winid].cursorline = true
  vim.wo[M._state.preview_winid].signcolumn = "no"

  pcall(vim.api.nvim_win_set_width, M._state.list_winid, math.floor(vim.o.columns * 0.25))

  vim.api.nvim_set_current_win(M._state.list_winid)
  -- Move cursor to the first stop line (skip past the header comments).
  local first_stop_lineno = M._first_stop_lineno(lines)
  if first_stop_lineno then
    pcall(vim.api.nvim_win_set_cursor, M._state.list_winid, { first_stop_lineno, 0 })
  end

  M._state.augroup = vim.api.nvim_create_augroup("codetour_edit", { clear = true })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = M._state.augroup,
    buffer = list_bufnr,
    callback = on_save,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = M._state.augroup,
    buffer = list_bufnr,
    callback = update_preview,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = M._state.augroup,
    buffer = list_bufnr,
    callback = cleanup_state,
  })

  vim.keymap.set("n", "<CR>", on_enter, { buffer = list_bufnr, silent = true, desc = "codetour: jump to stop" })
  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = list_bufnr, silent = true, desc = "codetour: close edit UI" })

  update_preview()
end

---Tear down the UI: close preview window, wipe list buffer, restore prev win.
function M.close()
  if M._state.preview_winid and vim.api.nvim_win_is_valid(M._state.preview_winid) then
    pcall(vim.api.nvim_win_close, M._state.preview_winid, true)
  end
  if M._state.list_bufnr and vim.api.nvim_buf_is_valid(M._state.list_bufnr) then
    -- BufWipeout autocmd will fire cleanup_state for us
    pcall(vim.api.nvim_buf_delete, M._state.list_bufnr, { force = true })
  else
    cleanup_state()
  end
end

return M
