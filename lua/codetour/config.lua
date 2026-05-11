local M = {}

---@class CodeTour.SignsOpts
---@field enabled? boolean Render a sign in the gutter at each stop's line (default: true)
---@field text? string? If set, use this fixed string for every stop's sign. If nil, use the stop's index. Max 2 cells.
---@field prefix? string? 1-cell glyph prepended to the index (e.g. "󰽪" = nerd-font bow). Only applied when index is single-digit (1-9). Set to nil to disable.
---@field highlight? string Highlight group to link CodetourSign to (default: "Special")

---@class CodeTour.Opts
---@field default_keymaps? boolean Register default <leader>t* keymaps (default: false)
---@field close_qf_on_tour_close? boolean Run :cclose in :CodeTour close (default: false)
---@field note_highlight? string Highlight group to link CodetourNote to (default: "DiagnosticInfo")
---@field note_prefix? string Template prefixed to each note. Placeholders: {name}, {idx}, {total}. Set to "" to disable.
---@field debug? boolean Show informational notifications. WARN/ERROR are always shown. Default false.
---@field storage_path? string Where tour files live. Relative paths join to the git root; absolute paths used as-is. Default ".codetour" (visible at repo root, easily committed/shared). Set to ".git/info/codetour" for the legacy hidden behavior.
---@field signs? CodeTour.SignsOpts Sign-column markers config

---@type CodeTour.Opts
M.defaults = {
  default_keymaps = false,
  close_qf_on_tour_close = false, -- if true, :CodeTour close runs :cclose; otherwise leaves the qf window alone
  note_highlight = "DiagnosticInfo", -- distinct from Comment so notes don't blend in
  note_prefix = "{name} ({idx}/{total}): ", -- scannable prefix; set to "" to disable
  debug = false, -- when false, INFO-level confirmations are suppressed; WARN/ERROR always show
  storage_path = ".codetour", -- relative to git root; visible & committable. Override with absolute path for non-git workflows.
  signs = {
    enabled = true,
    text = nil, -- nil = use the stop's 1-based index (1, 2, ...); set a string for a fixed marker like "●"
    -- 1-cell prefix prepended to the index (only for single-digit indices, since
    -- sign_text is capped at 2 cells). Default is the Nerd Font flag glyph
    -- `nf-md-flag` (U+F023B) — thematic "destination/waypoint" marker.
    -- If you don't have a Nerd Font, override to a plain unicode arrow like
    -- "▸" or set to "" to disable the prefix.
    prefix = "󰈻",
    highlight = "Special", -- linked via CodetourSign with default = true
  },
}

---@type CodeTour.Opts
M.opts = vim.deepcopy(M.defaults)

---@param user_opts CodeTour.Opts? User-supplied overrides; merged on top of M.defaults
function M.merge(user_opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, user_opts or {})
end

return M
