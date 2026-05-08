local M = {}

local CONTEXT_WIDTH = 60

---Strip leading/trailing whitespace and truncate to CONTEXT_WIDTH chars.
---Used for the `context` field on each stop so we can re-anchor after
---formatter runs or whitespace edits without false positives.
---@param line string?
---@return string
function M.trim_context(line)
  if line == nil then
    return ""
  end
  local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
  if #trimmed > CONTEXT_WIDTH then
    return trimmed:sub(1, CONTEXT_WIDTH)
  end
  return trimmed
end

---Canonicalize a path: expand to absolute, follow symlinks.
---Used for path equality across saved-file paths and live buffer paths
---(e.g. macOS `/tmp` vs `/private/tmp`).
---@param path string?
---@return string?
function M.canonical(path)
  if path == nil or path == "" then
    return nil
  end
  return vim.fn.resolve(vim.fn.fnamemodify(path, ":p"))
end

---Resolve nvim's "current buffer" sentinel `0` to the actual buffer number.
---Critical when using bufnr as a key in module-local tables: `0` is "current
---buffer" to nvim APIs but a literal `0` as a Lua table key, so without
---resolution multiple buffers' state ends up colliding under one key.
---@param bufnr integer
---@return integer
function M.actual_bufnr(bufnr)
  if bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

return M
