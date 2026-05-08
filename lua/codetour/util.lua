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

return M
