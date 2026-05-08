local M = {}

local NAMESPACE = vim.api.nvim_create_namespace "codetour"

-- bufnr -> { [idx_in_state.data.stops] = extmark_id }
-- Module-local because the map's lifetime is the session, and only this module
-- ever needs to read or write it.
M._buf_extmarks = {}

local function canonical(path)
  if path == nil or path == "" then
    return nil
  end
  return vim.fn.resolve(vim.fn.fnamemodify(path, ":p"))
end

local function buf_path(bufnr)
  return canonical(vim.api.nvim_buf_get_name(bufnr))
end

---Attach extmarks for any stops whose file matches this buffer's path.
---Idempotent: skips stops already tracked for this buffer.
---@param bufnr integer
---@param stops CodeTour.Stop[]
function M.attach(bufnr, stops)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local path = buf_path(bufnr)
  if path == nil then
    return
  end

  M._buf_extmarks[bufnr] = M._buf_extmarks[bufnr] or {}

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for idx, stop in ipairs(stops) do
    if M._buf_extmarks[bufnr][idx] == nil and canonical(stop.file) == path then
      local row = math.max(0, (stop.lnum or 1) - 1)
      row = math.min(row, math.max(0, line_count - 1)) -- clamp so set_extmark doesn't error on out-of-range
      local col = math.max(0, stop.col or 0)
      local id = vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, row, col, {})
      M._buf_extmarks[bufnr][idx] = id
    end
  end
end

---Read live extmark positions and write back into the matching stops
---(1-indexed lnum, 0-indexed col, matching the cursor convention).
---@param stops CodeTour.Stop[]
function M.refresh(stops)
  for bufnr, marks in pairs(M._buf_extmarks) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      for idx, id in pairs(marks) do
        local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, NAMESPACE, id, {})
        if pos and pos[1] then
          local stop = stops[idx]
          if stop then
            stop.lnum = pos[1] + 1
            stop.col = pos[2]
          end
        end
      end
    end
  end
end

---Drop the extmarks for one buffer (used when the buffer is being unloaded).
---@param bufnr integer
function M.detach(bufnr)
  if M._buf_extmarks[bufnr] then
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, NAMESPACE, 0, -1)
    end
    M._buf_extmarks[bufnr] = nil
  end
end

---Drop every extmark this plugin has set across every buffer.
---Called by state.start() before resetting the stop list.
function M.detach_all()
  for bufnr, _ in pairs(M._buf_extmarks) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, NAMESPACE, 0, -1)
    end
  end
  M._buf_extmarks = {}
end

return M
