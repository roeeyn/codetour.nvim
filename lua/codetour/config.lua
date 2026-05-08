local M = {}

---@class CodeTour.Opts
---@field default_keymaps? boolean Register default <leader>t* keymaps (default: false)
---@field close_qf_on_tour_close? boolean Run :cclose in :TourClose (default: false)
---@field note_highlight? string Highlight group to link CodetourNote to (default: "DiagnosticInfo")
---@field note_prefix? string Template prefixed to each note. Placeholders: {name}, {idx}, {total}. Set to "" to disable.
---@field debug? boolean Show informational notifications (e.g. "stop added", "tour created"). WARN/ERROR are always shown.

---@type CodeTour.Opts
M.defaults = {
  default_keymaps = false,
  close_qf_on_tour_close = false, -- if true, :TourClose runs :cclose; otherwise leaves the qf window alone
  note_highlight = "DiagnosticInfo", -- distinct from Comment so notes don't blend in
  note_prefix = "{name} ({idx}/{total}): ", -- scannable prefix; set to "" to disable
  debug = false, -- when false, INFO-level confirmations are suppressed; WARN/ERROR always show
}

---@type CodeTour.Opts
M.opts = vim.deepcopy(M.defaults)

---@param user_opts CodeTour.Opts? User-supplied overrides; merged on top of M.defaults
function M.merge(user_opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, user_opts or {})
end

return M
