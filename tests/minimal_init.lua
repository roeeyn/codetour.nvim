-- Minimal init for headless test runs.
-- Locates plenary via a small list of standard paths so this works both
-- on a developer machine (where plenary lives in lazy's plugin dir) and
-- in CI (where it's commonly cloned to tests/.deps/).

local plenary_paths = {
  vim.fn.stdpath "data" .. "/lazy/plenary.nvim",
  vim.fn.stdpath "data" .. "/site/pack/vendor/start/plenary.nvim",
  "tests/.deps/plenary.nvim",
}

local plenary_env = os.getenv "PLENARY_DIR"
if plenary_env and plenary_env ~= "" then
  table.insert(plenary_paths, 1, plenary_env)
end

for _, p in ipairs(plenary_paths) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.rtp:prepend(p)
    break
  end
end

-- Use absolute path so cwd-changing tests still resolve `require "codetour.*"`.
vim.opt.rtp:prepend(vim.fn.getcwd())

vim.cmd "runtime plugin/plenary.vim"
require "plenary.busted"
