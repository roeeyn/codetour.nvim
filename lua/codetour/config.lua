local M = {}

M.defaults = {
  default_keymaps = false,
  close_qf_on_tour_close = false, -- if true, :TourClose runs :cclose; otherwise leaves the qf window alone
}

M.opts = vim.deepcopy(M.defaults)

function M.merge(user_opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, user_opts or {})
end

return M
