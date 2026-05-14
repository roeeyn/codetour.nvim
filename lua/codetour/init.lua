local config = require "codetour.config"
local state = require "codetour.state"

local M = {}

local function set_default_keymaps()
  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { desc = desc, silent = true })
  end
  map("<leader>ta", function()
    require("codetour").add()
  end, "codetour: add stop at cursor")
  map("<leader>te", function()
    vim.ui.input({ prompt = "New note: " }, function(text)
      if text and text ~= "" then
        require("codetour").edit_note(text)
      end
    end)
  end, "codetour: edit nearest stop's note")
  map("<leader>tx", function()
    require("codetour").remove()
  end, "codetour: remove nearest stop")
  map("<leader>tn", "<cmd>cnext<cr>", "codetour: next stop (qf)")
  map("<leader>tp", "<cmd>cprev<cr>", "codetour: prev stop (qf)")
  map("<leader>to", function()
    require("codetour").open()
  end, "codetour: populate quickfix with active tour")
  map("<leader>tc", function()
    require("codetour").close()
  end, "codetour: restore prior quickfix")
  map("<leader>tl", function()
    require("codetour").list()
  end, "codetour: stop picker (active tour)")
  map("<leader>ts", function()
    require("codetour").pick_tour()
  end, "codetour: tour picker")
  map("<leader>tv", function()
    require("codetour").toggle_notes()
  end, "codetour: toggle virt_lines notes")
end

---@param opts CodeTour.Opts? User-supplied overrides; merged on top of defaults
function M.setup(opts)
  config.merge(opts)

  -- Re-apply the highlight link in case the user changed `note_highlight`. The
  -- plugin/ shim already set a default at startup; this lets setup() override it.
  vim.api.nvim_set_hl(0, "CodetourNote", { link = config.opts.note_highlight, default = true })

  if config.opts.default_keymaps then
    set_default_keymaps()
  end

  -- Cover the case where this plugin loads after some buffers were already
  -- read (e.g. lazy.nvim's default deferred loading): re-render decoration
  -- across all loaded buffers for the active tour's stops.
  state.ensure_loaded()
  require("codetour.decoration").refresh_all(state.data.active_tour)
end

function M.ping()
  vim.notify("codetour: pong", vim.log.levels.INFO)
end

---@param name string? Tour name (required)
function M.create(name)
  state.create(name)
end

---Open a tour. With a name, opens that tour (errors if not found). Without
---a name, opens the last-active tour if `_active_tour.txt` remembers one,
---otherwise falls back to a picker over all tours. Activating a tour turns
---on its decorations and populates the quickfix list (and schedules
---`cfirst` + `cwindow`).
---@param name string?
function M.open(name)
  if name == nil or name == "" then
    local storage_mod = require "codetour.storage"
    local last = storage_mod.read_active()
    if last then
      state.open(last)
      return
    end
    -- Nothing remembered → tour picker (it'll call state.open on choice)
    M.pick_tour()
    return
  end
  state.open(name)
end

---Close the currently-open tour: remove decorations + restore the prior qf
---list. The on-disk pointer is preserved so :CodeTour open (no args)
---reopens the same tour later.
function M.close()
  state.close()
end

---@param name string? Tour name to delete (required)
function M.delete(name)
  state.delete(name)
end

---@param new_name string? New name for the currently-active tour
function M.rename(new_name)
  state.rename(new_name)
end

---@return string[] tour names available in storage
function M.list_tours()
  return state.list_tours()
end

---Open a picker over the active tour's stops. Default action: jump to the stop.
function M.list()
  require("codetour.picker").stops()
end

---Open a picker over available tours. Default action: switch to that tour.
function M.pick_tour()
  require("codetour.picker").tours()
end

---@param note string? Optional note describing why this stop matters
function M.add(note)
  state.add(note)
end

function M.remove()
  state.remove()
end

function M.dump()
  state.dump()
end

---Open the oil-style UI buffer for the active tour. This is the plugin's
---primary interactive surface: jump to a stop with <CR>, edit notes inline,
---reorder by moving lines, delete by removing them, `:w` to apply, `q` to
---close. Named open_ui (rather than the old `edit`) because the buffer
---does much more than editing.
function M.open_ui()
  require("codetour.edit").open()
end

---Move cursor to the next stop *in the current buffer*, sorted by line.
---Pure cursor movement; no qf side effects, no state mutation.
function M.next_stop_in_buf()
  state.next_stop_in_buf()
end

---Move cursor to the previous stop *in the current buffer*, sorted by line.
function M.prev_stop_in_buf()
  state.prev_stop_in_buf()
end

---@param text string New note text for the stop nearest the cursor
function M.edit_note(text)
  state.edit_note(text)
end

function M.toggle_notes()
  local log = require "codetour.log"
  local visible = require("codetour.decoration").toggle_notes(state.data.active_tour)
  log.info("codetour: notes " .. (visible and "shown" or "hidden"))
end

return M
