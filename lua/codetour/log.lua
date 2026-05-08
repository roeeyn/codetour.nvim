local M = {}

---Show an informational message — only when `setup({ debug = true })`.
---Use for confirmations of successful operations where a visible state
---change (virt_line appears, qf updates, etc.) is the real feedback.
---@param msg string
function M.info(msg)
  local ok, config = pcall(require, "codetour.config")
  if not ok or not config.opts.debug then
    return
  end
  vim.notify(msg, vim.log.levels.INFO)
end

---Show a warning. Always visible. Use for refused operations, drift
---events, recovery actions, and missing-state hints.
---@param msg string
function M.warn(msg)
  vim.notify(msg, vim.log.levels.WARN)
end

---Show an error. Always visible. Use for IO failures and similar.
---@param msg string
function M.error(msg)
  vim.notify(msg, vim.log.levels.ERROR)
end

return M
