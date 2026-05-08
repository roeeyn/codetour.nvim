local M = {}

-- Returns { root, branch, file } if cwd is inside a git repo, otherwise nil.
-- `branch` is "no-branch" for detached HEAD; `file` is the absolute path
-- to this branch's persistence file (with `/` replaced by `_` in the name).
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
