local M = {}

local NAMESPACE = vim.api.nvim_create_namespace "codetour_signs"

-- bufnr -> { [idx] = sign_extmark_id }
M._buf_signs = {}

---Compute the sign text for a stop.
---Layered: signs.text override > prefix + single-digit index > index alone.
---Sign-column hard-limits to 2 cells, so the prefix only applies when the
---index is single-digit (1-9). Indices 10+ render as the bare number;
---indices 100+ collapse to "+".
---@param idx integer 1-based stop index in the active tour
---@return string
local function sign_text_for(idx)
  local config = require "codetour.config"
  local opts = config.opts.signs or {}

  if opts.text and opts.text ~= "" then
    return opts.text
  end

  local index_str = (idx >= 100) and "+" or tostring(idx)

  if opts.prefix and opts.prefix ~= "" and #index_str == 1 then
    return opts.prefix .. index_str
  end

  return index_str
end

local function set_sign(bufnr, idx, row)
  M._buf_signs[bufnr] = M._buf_signs[bufnr] or {}
  local existing = M._buf_signs[bufnr][idx]

  local opts = {
    sign_text = sign_text_for(idx),
    sign_hl_group = "CodetourSign",
  }
  if existing then
    opts.id = existing
  end

  local id = vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, row, 0, opts)
  M._buf_signs[bufnr][idx] = id
end

---Render signs for any stops anchored in this buffer.
---Like notes.refresh, this clears and rebuilds the namespace each call so
---a stale module-state vs nvim-state drift can't leave duplicate signs.
---@param bufnr integer
---@param stops CodeTour.Stop[]
function M.refresh(bufnr, stops)
  bufnr = require("codetour.util").actual_bufnr(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local config = require "codetour.config"
  local enabled = config.opts.signs and config.opts.signs.enabled
  if not enabled then
    return
  end

  -- Clear and rebuild — same self-healing pattern as notes.lua.
  vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
  M._buf_signs[bufnr] = {}

  local anchor = require "codetour.anchor"
  for idx, _ in ipairs(stops) do
    local row = anchor.row_of(bufnr, idx)
    if row ~= nil then
      set_sign(bufnr, idx, row)
    end
  end
end

---Walk every buffer the anchor module is tracking and refresh signs there.
---@param stops CodeTour.Stop[]
function M.refresh_all(stops)
  local anchor = require "codetour.anchor"
  for bufnr, _ in pairs(anchor._buf_extmarks) do
    M.refresh(bufnr, stops)
  end
end

---Drop every sign extmark across every buffer.
function M.detach_all()
  for bufnr, _ in pairs(M._buf_signs) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, NAMESPACE, 0, -1)
    end
  end
  M._buf_signs = {}
end

return M
