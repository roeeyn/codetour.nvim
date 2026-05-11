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

-- :CodeTour is the single user-command surface for everything codetour does.
-- No args → open the UI buffer (primary entry point, oil-style).
-- Subcommands cover the per-action operations: see `subcommands` below.
--
-- Why this shape: the plugin previously exposed a flat :Tour* family
-- (:TourCreate, :TourSelect, :TourAdd, :TourOpen, etc.). That made it
-- hard to discover related commands (you had to know the prefix) and
-- collided with any other plugin's :Tour*. Consolidating behind one
-- namespaced command with tab completion is the same pattern used by
-- :Telescope, :Mason, :Lazy, :Trouble — discovery via <Tab>, no collision.

local function tour_names(arglead)
  local ok, codetour = pcall(require, "codetour")
  if not ok then
    return {}
  end
  local matches = {}
  for _, name in ipairs(codetour.list_tours()) do
    if vim.startswith(name, arglead or "") then
      table.insert(matches, name)
    end
  end
  return matches
end

-- Each entry: handler is called with the rest of the cmdline (everything
-- after the subcommand name, as a single string). `complete` is the symbol
-- of a per-position-2 completion function, or nil for no further completion.
local subcommands = {
  create = {
    handler = function(args)
      require("codetour").create(args ~= "" and args or nil)
    end,
    desc = "Create a new empty tour and make it active",
  },
  select = {
    handler = function(args)
      if args == "" then
        require("codetour").pick_tour()
      else
        require("codetour").select(args)
      end
    end,
    complete = tour_names,
    desc = "Switch active tour (no arg → picker)",
  },
  delete = {
    handler = function(args)
      require("codetour").delete(args ~= "" and args or nil)
    end,
    complete = tour_names,
    desc = "Delete a tour by name (with confirm)",
  },
  add = {
    handler = function(args)
      require("codetour").add(args ~= "" and args or nil)
    end,
    desc = "Add a stop at the cursor (optional inline note)",
  },
  remove = {
    handler = function()
      require("codetour").remove()
    end,
    desc = "Remove the stop nearest the cursor",
  },
  note = {
    handler = function(args)
      require("codetour").edit_note(args)
    end,
    desc = "Replace the nearest stop's note with the given text",
  },
  open = {
    handler = function()
      require("codetour").open()
    end,
    desc = "Populate the quickfix list with the active tour",
  },
  close = {
    handler = function()
      require("codetour").close()
    end,
    desc = "Restore the prior quickfix list",
  },
  list = {
    handler = function()
      require("codetour").list()
    end,
    desc = "Picker over the active tour's stops",
  },
  ["next-stop"] = {
    handler = function()
      require("codetour").next_stop_in_buf()
    end,
    desc = "Cursor → next stop in current buffer (by line)",
  },
  ["prev-stop"] = {
    handler = function()
      require("codetour").prev_stop_in_buf()
    end,
    desc = "Cursor → previous stop in current buffer (by line)",
  },
  ["toggle-notes"] = {
    handler = function()
      require("codetour").toggle_notes()
    end,
    desc = "Show / hide virtual-text notes globally",
  },
  dump = {
    handler = function()
      require("codetour").dump()
    end,
    desc = "Print in-memory state to :messages (debug)",
  },
  ping = {
    handler = function()
      require("codetour").ping()
    end,
    desc = "Smoke-test command (debug)",
  },
}

local function dispatch(opts)
  -- No args → open the UI buffer (primary entry point).
  if opts.args == "" then
    require("codetour").open_ui()
    return
  end
  local subcmd, rest = opts.args:match "^(%S+)%s*(.*)$"
  if subcmd == nil then
    require("codetour").open_ui()
    return
  end
  local entry = subcommands[subcmd]
  if entry == nil then
    vim.notify(
      string.format("codetour: unknown subcommand '%s'. Try :CodeTour <Tab> for completions.", subcmd),
      vim.log.levels.ERROR
    )
    return
  end
  entry.handler(rest)
end

local function complete(arglead, cmdline, cursorpos)
  local before = cmdline:sub(1, cursorpos)
  local words = vim.split(before, "%s+", { trimempty = true })
  local ends_with_space = before:match "%s$" ~= nil

  -- `words` includes "CodeTour" as words[1]. Position 1 (subcommand) is
  -- being completed when we've typed nothing yet after the command name,
  -- or are mid-token on what will be the subcommand.
  local args_completed = ends_with_space and (#words - 1) or (#words - 2)
  local completing_index = args_completed + 1

  if completing_index == 1 then
    local matches = {}
    for name, _ in pairs(subcommands) do
      if vim.startswith(name, arglead or "") then
        table.insert(matches, name)
      end
    end
    table.sort(matches)
    return matches
  end

  -- Subcommand-specific completion (position 2+).
  local subcmd = words[2]
  local entry = subcmd and subcommands[subcmd] or nil
  if entry and entry.complete then
    return entry.complete(arglead)
  end
  return {}
end

vim.api.nvim_create_user_command("CodeTour", dispatch, {
  nargs = "*",
  complete = complete,
  desc = "codetour: open the UI buffer (no args) or run a subcommand. <Tab> for completions.",
})
