local M = {}

---@class CodeTour.GitInfo
---@field root string Absolute path to the git working tree root
---@field branch string Branch name; "no-branch" for detached HEAD
---@field file string Absolute path to <root>/.git/info/codetour/<branch>.json (slashes in the branch are replaced with `_`)

---Probes git for repo info. Cheap (two `vim.fn.system` calls); callers can invoke per-command.
---@return CodeTour.GitInfo? info nil if cwd is not inside a git repo
function M.info()
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

return M
