if vim.g.loaded_codetour == 1 then
  return
end
vim.g.loaded_codetour = 1

local codetour_group = vim.api.nvim_create_augroup("codetour", { clear = true })

-- Define our highlight group with `default = true` so user :hi overrides win.
-- Re-set on ColorScheme so a `:colorscheme ...` that calls `:hi clear` doesn't wipe us.
local function set_default_hl()
  vim.api.nvim_set_hl(0, "CodetourNote", { link = "Comment", default = true })
end
set_default_hl()
vim.api.nvim_create_autocmd("ColorScheme", { group = codetour_group, callback = set_default_hl })

vim.api.nvim_create_autocmd("BufRead", {
  group = codetour_group,
  callback = function(args)
    local state = require "codetour.state"
    state.ensure_loaded()
    local anchor = require "codetour.anchor"
    anchor.attach(args.buf, state.data.stops)
    local notes = require "codetour.notes"
    notes.refresh(args.buf, state.data.stops)
  end,
})

vim.api.nvim_create_user_command("TourPing", function()
  require("codetour").ping()
end, { desc = "codetour: smoke-test command" })

vim.api.nvim_create_user_command("TourStart", function(args)
  local name = args.args ~= "" and args.args or nil
  require("codetour").start(name)
end, { nargs = "?", desc = "codetour: start a new path (optional name)" })

vim.api.nvim_create_user_command("TourAdd", function(args)
  local note = args.args ~= "" and args.args or nil
  require("codetour").add(note)
end, { nargs = "*", desc = "codetour: add a stop at cursor (optional note)" })

vim.api.nvim_create_user_command("TourDump", function()
  require("codetour").dump()
end, { desc = "codetour: print state for debugging" })

vim.api.nvim_create_user_command("TourOpen", function()
  require("codetour").open()
end, { desc = "codetour: populate quickfix with current path; jump to stop 1" })

vim.api.nvim_create_user_command("TourClose", function()
  require("codetour").close()
end, { desc = "codetour: restore prior quickfix and close cwindow" })

vim.api.nvim_create_user_command("TourNoteEdit", function(args)
  require("codetour").edit_note(args.args)
end, { nargs = "*", desc = "codetour: replace the nearest stop's note with the given text" })

vim.api.nvim_create_user_command("TourNotesToggle", function()
  require("codetour").toggle_notes()
end, { desc = "codetour: show/hide all stop notes" })
