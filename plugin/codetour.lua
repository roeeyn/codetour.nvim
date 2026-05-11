if vim.g.loaded_codetour == 1 then
  return
end
vim.g.loaded_codetour = 1

local codetour_group = vim.api.nvim_create_augroup("codetour", { clear = true })

-- Define our highlight groups with `default = true` so user :hi overrides win.
-- Re-set on ColorScheme so a `:colorscheme ...` that calls `:hi clear` doesn't wipe us.
local function set_default_hl()
  local ok, config = pcall(require, "codetour.config")
  local note_link = ok and config.opts.note_highlight or "DiagnosticInfo"
  local sign_link = ok and config.opts.signs and config.opts.signs.highlight or "Special"
  vim.api.nvim_set_hl(0, "CodetourNote", { link = note_link, default = true })
  vim.api.nvim_set_hl(0, "CodetourSign", { link = sign_link, default = true })
end
set_default_hl()
vim.api.nvim_create_autocmd("ColorScheme", { group = codetour_group, callback = set_default_hl })

vim.api.nvim_create_autocmd("BufRead", {
  group = codetour_group,
  callback = function(args)
    local state = require "codetour.state"
    state.ensure_loaded()
    require("codetour.decoration").attach_buffer(args.buf, state.data.active_tour)
  end,
})

local function tour_complete()
  local ok, codetour = pcall(require, "codetour")
  if not ok then
    return {}
  end
  return codetour.list_tours()
end

vim.api.nvim_create_user_command("TourPing", function()
  require("codetour").ping()
end, { desc = "codetour: smoke-test command" })

vim.api.nvim_create_user_command("TourCreate", function(args)
  local name = args.args ~= "" and args.args or nil
  require("codetour").create(name)
end, { nargs = "?", desc = "codetour: create a new tour and make it active" })

vim.api.nvim_create_user_command("TourSelect", function(args)
  if args.args == "" then
    -- No arg → open the tour picker.
    require("codetour").pick_tour()
  else
    require("codetour").select(args.args)
  end
end, {
  nargs = "?",
  complete = tour_complete,
  desc = "codetour: switch the active tour (no arg opens a picker)",
})

vim.api.nvim_create_user_command("TourDelete", function(args)
  local name = args.args ~= "" and args.args or nil
  require("codetour").delete(name)
end, {
  nargs = "?",
  complete = tour_complete,
  desc = "codetour: delete a tour by name",
})

vim.api.nvim_create_user_command("TourAdd", function(args)
  local note = args.args ~= "" and args.args or nil
  require("codetour").add(note)
end, { nargs = "*", desc = "codetour: add a stop at cursor to the active tour" })

vim.api.nvim_create_user_command("TourRemove", function()
  require("codetour").remove()
end, { desc = "codetour: remove the nearest stop in the current buffer" })

vim.api.nvim_create_user_command("TourNoteEdit", function(args)
  require("codetour").edit_note(args.args)
end, { nargs = "*", desc = "codetour: replace the nearest stop's note with the given text" })

vim.api.nvim_create_user_command("TourNotesVirtualTextToggle", function()
  require("codetour").toggle_notes()
end, { desc = "codetour: show/hide the virtual-text rendering of stop notes" })

vim.api.nvim_create_user_command("TourOpen", function()
  require("codetour").open()
end, { desc = "codetour: populate quickfix with current tour; jump to stop 1" })

vim.api.nvim_create_user_command("TourClose", function()
  require("codetour").close()
end, { desc = "codetour: restore prior quickfix and close cwindow" })

vim.api.nvim_create_user_command("TourList", function()
  require("codetour").list()
end, { desc = "codetour: open a picker over stops in the active tour" })

vim.api.nvim_create_user_command("TourEdit", function()
  require("codetour").edit()
end, { desc = "codetour: open the editable list+preview UI for the active tour" })

vim.api.nvim_create_user_command("TourNextStop", function()
  require("codetour").next_stop_in_buf()
end, { desc = "codetour: move cursor to next stop in current buffer (by line, not index)" })

vim.api.nvim_create_user_command("TourPrevStop", function()
  require("codetour").prev_stop_in_buf()
end, { desc = "codetour: move cursor to previous stop in current buffer (by line, not index)" })

vim.api.nvim_create_user_command("TourDump", function()
  require("codetour").dump()
end, { desc = "codetour: print state for debugging" })
