local git = require "codetour.git"
local storage = require "codetour.storage"

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

local function init_git_repo(dir)
  vim.fn.system { "git", "-C", dir, "init", "-q", "-b", "main" }
  vim.fn.system { "git", "-C", dir, "commit", "--allow-empty", "-m", "init", "-q" }
end

describe("codetour.git", function()
  local original_cwd
  before_each(function()
    original_cwd = vim.fn.getcwd()
  end)
  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end)

  it("returns nil outside a git repo", function()
    local d = tmpdir()
    vim.cmd("cd " .. vim.fn.fnameescape(d))
    assert.is_nil(git.info())
  end)

  it("returns root/branch/file inside a repo on main", function()
    local d = tmpdir()
    init_git_repo(d)
    vim.cmd("cd " .. vim.fn.fnameescape(d))
    local info = git.info()
    assert.is_not_nil(info)
    assert.equals("main", info.branch)
    assert.is_truthy(info.file:match "/%.git/info/codetour/main%.json$")
  end)

  it("replaces / with _ in branch names for the file path", function()
    local d = tmpdir()
    init_git_repo(d)
    vim.cmd("cd " .. vim.fn.fnameescape(d))
    vim.fn.system { "git", "-C", d, "checkout", "-q", "-b", "feature/foo" }
    local info = git.info()
    assert.equals("feature/foo", info.branch)
    assert.is_truthy(info.file:match "/feature_foo%.json$")
  end)
end)

describe("codetour.storage", function()
  local original_cwd
  local repo

  before_each(function()
    original_cwd = vim.fn.getcwd()
    repo = tmpdir()
    init_git_repo(repo)
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
  end)
  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end)

  it("returns nil when no tour file exists", function()
    assert.is_nil(storage.load "missing")
  end)

  it("list_tours returns empty when no tours exist", function()
    assert.equals(0, #storage.list_tours())
  end)

  it("round-trips an empty tour", function()
    storage.save("default", {})
    local loaded = storage.load "default"
    assert.is_not_nil(loaded)
    assert.equals("default", loaded.name)
    assert.equals(0, #loaded.stops)
  end)

  it("converts absolute paths to relative on save and back on load", function()
    local info = git.info()
    local stops = {
      { file = info.root .. "/foo.lua", lnum = 10, col = 0, note = "entry" },
      { file = info.root .. "/bar/baz.py", lnum = 42, col = 4, note = "" },
    }
    storage.save("auth", stops)

    -- On-disk uses relative paths
    local on_disk = info.root .. "/.git/info/codetour/auth.json"
    local f = io.open(on_disk, "r")
    local raw = f:read "*a"
    f:close()
    local decoded = vim.fn.json_decode(raw)
    assert.equals("auth", decoded.name)
    assert.equals("foo.lua", decoded.stops[1].file)
    assert.equals("bar/baz.py", decoded.stops[2].file)

    -- Load reconstructs absolute paths
    local loaded = storage.load "auth"
    assert.equals(info.root .. "/foo.lua", loaded.stops[1].file)
    assert.equals(10, loaded.stops[1].lnum)
    assert.equals("entry", loaded.stops[1].note)
  end)

  it("returns nil on malformed JSON", function()
    local info = git.info()
    local file = info.root .. "/.git/info/codetour/auth.json"
    vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
    local f = io.open(file, "w")
    f:write "garbage{{{"
    f:close()
    assert.is_nil(storage.load "auth")
  end)

  it("active-tour pointer round-trips", function()
    assert.is_nil(storage.read_active())
    storage.write_active "auth"
    assert.equals("auth", storage.read_active())
    storage.write_active(nil)
    assert.is_nil(storage.read_active())
  end)

  it("delete removes the tour file", function()
    storage.save("doomed", {})
    assert.is_not_nil(storage.load "doomed")
    assert.is_true(storage.delete "doomed")
    assert.is_nil(storage.load "doomed")
  end)

  it("list_tours sorts and excludes the _active_tour pointer", function()
    storage.save("billing", {})
    storage.save("auth", {})
    storage.write_active "auth"
    local tours = storage.list_tours()
    assert.same({ "auth", "billing" }, tours)
  end)
end)

describe("codetour.util", function()
  local util

  before_each(function()
    package.loaded["codetour.util"] = nil
    util = require "codetour.util"
  end)

  it("trim_context strips leading and trailing whitespace", function()
    assert.equals("foo", util.trim_context "  foo  ")
    assert.equals("foo bar", util.trim_context "\tfoo bar\n")
  end)

  it("trim_context truncates to 60 chars", function()
    local long = string.rep("a", 100)
    assert.equals(60, #util.trim_context(long))
  end)

  it("trim_context returns empty string for nil or whitespace-only input", function()
    assert.equals("", util.trim_context(nil))
    assert.equals("", util.trim_context "   ")
  end)
end)

describe("codetour.anchor", function()
  local anchor

  before_each(function()
    package.loaded["codetour.anchor"] = nil
    anchor = require "codetour.anchor"
  end)
  after_each(function()
    anchor.detach_all()
  end)

  local function buffer_with_lines(lines)
    local tmp = vim.fn.tempname()
    vim.fn.writefile(lines, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    return vim.api.nvim_get_current_buf(), tmp
  end

  it("attach() sets an extmark for a stop matching the buffer", function()
    local bufnr, file = buffer_with_lines { "line 1", "line 2", "line 3", "line 4", "line 5" }
    local stops = { { file = file, lnum = 3, col = 0, note = "" } }
    anchor.attach(bufnr, stops)
    assert.is_not_nil(anchor._buf_extmarks[bufnr])
    assert.is_not_nil(anchor._buf_extmarks[bufnr][1])
  end)

  it("refresh() updates stop.lnum when lines are inserted above", function()
    local bufnr, file = buffer_with_lines { "line 1", "line 2", "line 3", "line 4", "line 5" }
    local stops = { { file = file, lnum = 3, col = 0, note = "" } }
    anchor.attach(bufnr, stops)

    -- Insert 2 lines above the stop
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new1", "new2" })

    anchor.refresh(stops)
    assert.equals(5, stops[1].lnum) -- was 3, now 5 after 2 lines inserted above
  end)

  it("refresh() updates stop.lnum when lines are deleted above", function()
    local bufnr, file = buffer_with_lines { "line 1", "line 2", "line 3", "line 4", "line 5" }
    local stops = { { file = file, lnum = 4, col = 0, note = "" } }
    anchor.attach(bufnr, stops)

    -- Delete the first line
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {})

    anchor.refresh(stops)
    assert.equals(3, stops[1].lnum) -- was 4, now 3 after 1 line deleted above
  end)

  it("attach() skips stops that don't match the buffer's path", function()
    local bufnr, file = buffer_with_lines { "line 1", "line 2", "line 3" }
    local stops = {
      { file = file, lnum = 1, col = 0, note = "match" },
      { file = "/some/other/file.lua", lnum = 1, col = 0, note = "no match" },
    }
    anchor.attach(bufnr, stops)
    assert.is_not_nil(anchor._buf_extmarks[bufnr][1])
    assert.is_nil(anchor._buf_extmarks[bufnr][2])
  end)

  it("attach() is idempotent (calling twice doesn't double-track)", function()
    local bufnr, file = buffer_with_lines { "line 1", "line 2" }
    local stops = { { file = file, lnum = 1, col = 0, note = "" } }
    anchor.attach(bufnr, stops)
    local first_id = anchor._buf_extmarks[bufnr][1]
    anchor.attach(bufnr, stops)
    assert.equals(first_id, anchor._buf_extmarks[bufnr][1])
  end)

  it("detach_all() clears every tracked extmark", function()
    local bufnr, file = buffer_with_lines { "line 1", "line 2" }
    local stops = { { file = file, lnum = 1, col = 0, note = "" } }
    anchor.attach(bufnr, stops)
    assert.is_not_nil(anchor._buf_extmarks[bufnr])
    anchor.detach_all()
    assert.is_nil(next(anchor._buf_extmarks))
  end)

  it("attach() re-anchors when context is found at a different line", function()
    -- File on disk now has the original content shifted down by 2 lines
    local bufnr, file = buffer_with_lines {
      "new line 1",
      "new line 2",
      "line 1",
      "line 2",
      "function dispatch(args)",
      "line 4",
    }
    -- Persisted state thinks the function is at line 3, with that snippet as context
    local stops = {
      { file = file, lnum = 3, col = 0, note = "the dispatch fn", context = "function dispatch(args)" },
    }
    anchor.attach(bufnr, stops)
    -- Should have re-anchored to line 5 and updated lnum
    assert.equals(5, stops[1].lnum)
  end)

  it("attach() honours stored lnum when context still matches there", function()
    local bufnr, file = buffer_with_lines { "line 1", "function dispatch(args)", "line 3" }
    local stops = {
      { file = file, lnum = 2, col = 0, note = "", context = "function dispatch(args)" },
    }
    anchor.attach(bufnr, stops)
    assert.equals(2, stops[1].lnum) -- unchanged
  end)

  it("attach() falls back to stored lnum when context is missing", function()
    local bufnr, file = buffer_with_lines { "line 1", "line 2", "line 3" }
    -- No context field: simulates a path file from before Phase 5 (or a stop on a blank line)
    local stops = { { file = file, lnum = 2, col = 0, note = "", context = "" } }
    anchor.attach(bufnr, stops)
    assert.equals(2, stops[1].lnum)
  end)

  it("attach() falls back to stored lnum when context is not found anywhere", function()
    local bufnr, file = buffer_with_lines { "line 1", "totally unrelated content", "line 3" }
    local stops = {
      { file = file, lnum = 2, col = 0, note = "", context = "function dispatch(args)" },
    }
    anchor.attach(bufnr, stops)
    assert.equals(2, stops[1].lnum) -- no match found, stays at stored lnum
  end)

  it("refresh() updates context from the live line content", function()
    local original = "function foo()"
    local bufnr, file = buffer_with_lines { original, "line 2" }
    local stops = {
      { file = file, lnum = 1, col = 0, note = "", context = original },
    }
    anchor.attach(bufnr, stops)
    -- Replace the line's bytes in place so the extmark stays put on row 0.
    -- (set_lines would treat this as delete-then-insert and the extmark moves off-row.)
    vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, #original, { "function foo_renamed()" })
    anchor.refresh(stops)
    assert.equals("function foo_renamed()", stops[1].context)
  end)
end)

describe("codetour.notes", function()
  local notes
  local anchor

  before_each(function()
    package.loaded["codetour.notes"] = nil
    package.loaded["codetour.anchor"] = nil
    notes = require "codetour.notes"
    anchor = require "codetour.anchor"
  end)
  after_each(function()
    notes.detach_all()
    anchor.detach_all()
  end)

  local function buffer_with_lines(lines)
    local tmp = vim.fn.tempname()
    vim.fn.writefile(lines, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    return vim.api.nvim_get_current_buf(), tmp
  end

  it("refresh() registers a note extmark for stops with notes", function()
    local bufnr, file = buffer_with_lines { "line 1", "line 2", "line 3" }
    local stops = { { file = file, lnum = 2, col = 0, note = "the dispatch fn", context = "" } }
    anchor.attach(bufnr, stops)
    notes.refresh(bufnr, stops)
    assert.is_not_nil(notes._buf_marks[bufnr])
    assert.is_not_nil(notes._buf_marks[bufnr][1])
  end)

  it("refresh() does nothing when notes are toggled off", function()
    local bufnr, file = buffer_with_lines { "line 1", "line 2" }
    local stops = { { file = file, lnum = 1, col = 0, note = "hello", context = "" } }
    anchor.attach(bufnr, stops)
    notes._visible = false
    notes.refresh(bufnr, stops)
    assert.is_nil(notes._buf_marks[bufnr])
  end)

  it("toggle() flips visibility and clears note extmarks when hiding", function()
    local bufnr, file = buffer_with_lines { "line 1", "line 2" }
    local stops = { { file = file, lnum = 1, col = 0, note = "hello", context = "" } }
    anchor.attach(bufnr, stops)
    notes.refresh(bufnr, stops)
    assert.is_not_nil(notes._buf_marks[bufnr][1])

    local visible = notes.toggle(stops)
    assert.is_false(visible)
    assert.is_nil(next(notes._buf_marks))
  end)

  it("toggle() restores notes when re-shown", function()
    local bufnr, file = buffer_with_lines { "line 1", "line 2" }
    local stops = { { file = file, lnum = 1, col = 0, note = "hello", context = "" } }
    anchor.attach(bufnr, stops)
    notes.refresh(bufnr, stops)
    notes.toggle(stops) -- now hidden
    notes.toggle(stops) -- now shown again
    assert.is_not_nil(notes._buf_marks[bufnr][1])
  end)

  it("renders notes for line-1 stops below the line (workaround for nvim limitation)", function()
    -- virt_lines_above = true at row 0 silently fails to render (nvim has no
    -- display row above line 1). Our fallback flips to virt_lines_above = false
    -- when row == 0 so the note stays visible.
    local bufnr, file = buffer_with_lines { "first line", "second line", "third line" }
    local stops = { { file = file, lnum = 1, col = 0, note = "stop on line 1", context = "" } }
    anchor.attach(bufnr, stops)
    notes.refresh(bufnr, stops, "default")

    local NS = vim.api.nvim_create_namespace "codetour_notes"
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
    assert.equals(1, #marks)
    assert.equals(0, marks[1][2], "extmark should be at row 0")
    assert.is_false(
      marks[1][4].virt_lines_above,
      "virt_lines_above should be false for row 0 so the note actually renders"
    )
  end)

  it("renders notes above the line for any row > 0", function()
    local bufnr, file = buffer_with_lines { "first line", "second line", "third line" }
    local stops = { { file = file, lnum = 2, col = 0, note = "stop on line 2", context = "" } }
    anchor.attach(bufnr, stops)
    notes.refresh(bufnr, stops, "default")

    local NS = vim.api.nvim_create_namespace "codetour_notes"
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
    assert.is_true(marks[1][4].virt_lines_above, "row > 0 should still render above")
  end)

  it("detach_all() clears every tracked note extmark", function()
    local bufnr, file = buffer_with_lines { "line 1" }
    local stops = { { file = file, lnum = 1, col = 0, note = "hello", context = "" } }
    anchor.attach(bufnr, stops)
    notes.refresh(bufnr, stops)
    notes.detach_all()
    assert.is_nil(next(notes._buf_marks))
  end)

  it("refresh() prepends the line's leading indent to the virt_lines text", function()
    local bufnr, file = buffer_with_lines {
      "function outer()",
      "    local x = 1", -- 4-space indent
      "        nested()", -- 8-space indent
    }
    local stops = {
      { file = file, lnum = 2, col = 0, note = "the local", context = "" },
      { file = file, lnum = 3, col = 0, note = "the nested call", context = "" },
    }
    anchor.attach(bufnr, stops)
    -- Disable prefix for this test so we can assert the indent cleanly
    require("codetour.config").merge { note_prefix = "" }
    notes.refresh(bufnr, stops, "default")

    local NS = vim.api.nvim_create_namespace "codetour_notes"
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
    local virt_at = {}
    for _, m in ipairs(marks) do
      virt_at[m[2]] = m[4].virt_lines
    end
    assert.equals("    the local", virt_at[1][1][1][1])
    assert.equals("        the nested call", virt_at[2][1][1][1])
  end)

  it("refresh() applies the configured prefix template with placeholders", function()
    local bufnr, file = buffer_with_lines { "line 1", "line 2" }
    local stops = {
      { file = file, lnum = 1, col = 0, note = "first", context = "" },
      { file = file, lnum = 2, col = 0, note = "second", context = "" },
    }
    anchor.attach(bufnr, stops)
    require("codetour.config").merge { note_prefix = "{name} ({idx}/{total}): " }
    notes.refresh(bufnr, stops, "billing")

    local NS = vim.api.nvim_create_namespace "codetour_notes"
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
    local virt_at = {}
    for _, m in ipairs(marks) do
      virt_at[m[2]] = m[4].virt_lines
    end
    assert.equals("billing (1/2): first", virt_at[0][1][1][1])
    assert.equals("billing (2/2): second", virt_at[1][1][1][1])
  end)

  it("refresh() leaves unknown placeholders intact (typo visibility)", function()
    local bufnr, file = buffer_with_lines { "line 1" }
    local stops = { { file = file, lnum = 1, col = 0, note = "hi", context = "" } }
    anchor.attach(bufnr, stops)
    require("codetour.config").merge { note_prefix = "{nme}: " } -- typo: {nme} not {name}
    notes.refresh(bufnr, stops, "default")

    local NS = vim.api.nvim_create_namespace "codetour_notes"
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
    assert.equals("{nme}: hi", marks[1][4].virt_lines[1][1][1])
  end)
end)

describe("codetour.picker", function()
  local original_cwd
  local repo
  local original_select

  before_each(function()
    original_cwd = vim.fn.getcwd()
    repo = tmpdir()
    init_git_repo(repo)
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    package.loaded["codetour.state"] = nil
    package.loaded["codetour.anchor"] = nil
    package.loaded["codetour.notes"] = nil
    package.loaded["codetour.picker"] = nil
    original_select = vim.ui.select
  end)
  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
    vim.ui.select = original_select
  end)

  it("stops() bails with notify when no active tour", function()
    local picker = require "codetour.picker"
    local called = false
    vim.ui.select = function()
      called = true
    end
    picker.stops()
    assert.is_false(called, "should not have opened a picker")
  end)

  it("stops() bails when active tour has no stops", function()
    local state = require "codetour.state"
    state.create "empty"
    local picker = require "codetour.picker"
    local called = false
    vim.ui.select = function()
      called = true
    end
    picker.stops()
    assert.is_false(called)
  end)

  it("stops() opens a picker with one entry per stop", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))

    local state = require "codetour.state"
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "first"
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    state.add "third"

    local captured_items
    vim.ui.select = function(items, _, on_choice)
      captured_items = items
      on_choice(items[2]) -- pick the second stop
    end

    require("codetour.picker").stops()
    assert.equals(2, #captured_items)
    assert.is_truthy(captured_items[1].display:match "first")
    assert.is_truthy(captured_items[2].display:match "third")
    -- Default action jumped to the second stop's line
    assert.equals(3, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("tours() bails when no tours exist", function()
    local picker = require "codetour.picker"
    local called = false
    vim.ui.select = function()
      called = true
    end
    picker.tours()
    assert.is_false(called)
  end)

  it("tours() shows all tours with stop counts and active marker", function()
    local state = require "codetour.state"
    state.create "auth"
    state.create "billing" -- now active

    local captured_items
    vim.ui.select = function(items, _, _)
      captured_items = items
    end

    require("codetour.picker").tours()
    assert.equals(2, #captured_items)
    -- Find the active one
    local active_entry
    for _, e in ipairs(captured_items) do
      if e.tour.is_active then
        active_entry = e
      end
    end
    assert.equals("billing", active_entry.tour.name)
    assert.is_truthy(active_entry.display:match "active")
  end)

  it("tours() default action selects the chosen tour", function()
    local state = require "codetour.state"
    state.create "auth"
    state.create "billing"
    assert.equals("billing", state.data.active_tour)

    vim.ui.select = function(items, _, on_choice)
      -- pick the first entry (auth, since list_tours sorts alphabetically)
      on_choice(items[1])
    end

    require("codetour.picker").tours()
    assert.equals("auth", state.data.active_tour, "picker should switch to chosen tour")
  end)
end)

describe("codetour.state", function()
  local state
  local original_cwd
  local repo

  before_each(function()
    original_cwd = vim.fn.getcwd()
    repo = tmpdir()
    init_git_repo(repo)
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    -- Re-require state, anchor, and notes so all module-local maps start
    -- empty per test (otherwise _buf_extmarks/_buf_marks leak across tests
    -- and anchor.attach silently skips "already tracked" indices).
    package.loaded["codetour.state"] = nil
    package.loaded["codetour.anchor"] = nil
    package.loaded["codetour.notes"] = nil
    state = require "codetour.state"
  end)
  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end)

  it("create() makes a new tour active and persists an empty file", function()
    state.create "auth"
    assert.equals("auth", state.data.active_tour)
    assert.equals(0, #state.data.stops)
    -- Active pointer was written
    assert.equals("auth", storage.read_active())
    -- Tour file was created
    local tours = storage.list_tours()
    assert.same({ "auth" }, tours)
  end)

  it("create() refuses tour names with path-unsafe characters", function()
    state.create "auth/v2"
    assert.is_nil(state.data.active_tour, "should not create tour with /")
    assert.equals(0, #storage.list_tours())
    state.create "auth\\v2"
    assert.is_nil(state.data.active_tour)
    state.create "auth:v2"
    assert.is_nil(state.data.active_tour)
  end)

  it("create() refuses to create a tour with an existing name", function()
    state.create "auth"
    state.data.active_tour = nil -- pretend nothing's active
    state.create "auth" -- should refuse
    -- Original tour file still there, new one wasn't overwritten
    assert.same({ "auth" }, storage.list_tours())
  end)

  it("select() switches the active tour and reloads its stops", function()
    state.create "auth"
    -- pretend we added a stop manually
    state.data.stops = { { file = "/x", lnum = 1, col = 0, note = "auth-stop", context = "" } }
    storage.save("auth", state.data.stops)

    state.create "billing"
    assert.equals("billing", state.data.active_tour)
    assert.equals(0, #state.data.stops)

    state.select "auth"
    assert.equals("auth", state.data.active_tour)
    assert.equals("auth-stop", state.data.stops[1].note)
  end)

  it("select() warns and no-ops when the tour doesn't exist", function()
    state.create "auth"
    state.select "nope"
    assert.equals("auth", state.data.active_tour, "active tour should be unchanged")
  end)

  it("delete() removes a non-active tour and leaves active alone", function()
    state.create "auth"
    state.create "billing" -- now active = billing
    -- Stub confirm to always accept
    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 1
    end
    state.delete "auth"
    vim.fn.confirm = original_confirm
    assert.same({ "billing" }, storage.list_tours())
    assert.equals("billing", state.data.active_tour)
  end)

  it("delete() clears active state when deleting the active tour", function()
    state.create "auth"
    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 1
    end
    state.delete "auth"
    vim.fn.confirm = original_confirm
    assert.is_nil(state.data.active_tour)
    assert.equals(0, #storage.list_tours())
    assert.is_nil(storage.read_active())
  end)

  it("ensure_loaded() restores the last-active tour on a fresh load", function()
    state.create "billing"
    -- New module instance, simulating nvim restart
    package.loaded["codetour.state"] = nil
    local fresh = require "codetour.state"
    fresh.ensure_loaded()
    assert.equals("billing", fresh.data.active_tour)
  end)

  it("ensure_loaded() clears the active pointer when the file is missing", function()
    storage.write_active "ghost" -- pointer to nonexistent tour
    package.loaded["codetour.state"] = nil
    local fresh = require "codetour.state"
    fresh.ensure_loaded()
    assert.is_nil(fresh.data.active_tour, "phantom pointer should be cleared")
    assert.is_nil(storage.read_active())
  end)

  it("add() auto-creates 'default' tour for friction-free first use", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "line 1" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "first"
    assert.equals("default", state.data.active_tour)
    assert.equals(1, #state.data.stops)
  end)

  it("edit_note() requires an active tour", function()
    state.data.loaded = true -- skip ensure_loaded; no active tour
    state.edit_note "anything"
    -- Nothing crashes; nothing happens
    assert.is_nil(state.data.active_tour)
  end)

  it("remove() requires an active tour", function()
    state.data.loaded = true
    state.remove()
    assert.is_nil(state.data.active_tour)
  end)

  it("edit_note() rejects empty text", function()
    state.data.stops = { { file = "/anything", lnum = 1, col = 0, note = "old", context = "" } }
    state.edit_note ""
    assert.equals("old", state.data.stops[1].note)
    state.edit_note(nil)
    assert.equals("old", state.data.stops[1].note)
  end)

  it("edit_note() updates the nearest stop's note in the current buffer", function()
    -- Open a real file so the buffer's path matches the stop's file
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "line 1", "line 2", "line 3" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    state.data.stops = {
      { file = tmp, lnum = 1, col = 0, note = "first", context = "" },
      { file = tmp, lnum = 2, col = 0, note = "second", context = "" },
      { file = tmp, lnum = 3, col = 0, note = "third", context = "" },
    }
    state.data.loaded = true
    state.data.active_tour = "default"

    state.edit_note "rewritten"
    assert.equals("rewritten", state.data.stops[2].note) -- nearest to cursor on line 2
    assert.equals("first", state.data.stops[1].note) -- unchanged
    assert.equals("third", state.data.stops[3].note) -- unchanged
  end)

  it("edit_note() bails when no stop is in the current buffer", function()
    vim.cmd "enew"
    state.data.stops = { { file = "/elsewhere/file.lua", lnum = 1, col = 0, note = "old", context = "" } }
    state.data.loaded = true
    state.edit_note "rewritten"
    assert.equals("old", state.data.stops[1].note)
  end)

  it("edit_note() refreshes the quickfix list when a tour is active", function()
    -- Build a real file and a real stop, prime an active tour qf
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "line 1", "line 2" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    state.data.stops = { { file = tmp, lnum = 1, col = 0, note = "before", context = "" } }
    state.data.loaded = true
    state.data.active_tour = "default"

    -- Simulate :TourOpen by populating a tour-titled qf list
    vim.fn.setqflist({}, " ", {
      title = "tour:test",
      items = { { filename = tmp, lnum = 1, col = 1, text = "before" } },
    })

    state.edit_note "after"

    local items = vim.fn.getqflist()
    assert.equals("after", items[1].text)
  end)

  it("does not duplicate virt_lines when _buf_marks is stale (module reload case)", function()
    -- Simulates the exact scenario the user hit: extmarks survive in the buffer
    -- (because they're nvim-side state) but our in-memory _buf_marks gets reset
    -- (e.g. lazy.nvim dev reload, :Lazy reload, package.loaded clear). Without
    -- the defensive rebuild, refresh would create a NEW extmark for a stop that
    -- already has one, and the user sees two virt_lines stacked.
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "line 1", "line 2", "line 3" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    local bufnr = vim.api.nvim_get_current_buf()

    package.loaded["codetour.state"] = nil
    package.loaded["codetour.notes"] = nil
    package.loaded["codetour.anchor"] = nil
    local state = require "codetour.state"
    local notes = require "codetour.notes"

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "first"

    -- Wipe in-memory note tracking but leave the buffer's extmark intact.
    notes._buf_marks = {}

    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    state.add "second"

    local NS = vim.api.nvim_create_namespace "codetour_notes"
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, {})
    assert.equals(2, #marks, "expected exactly 2 note extmarks (one per stop), not duplicates from stale state")
  end)

  it("adding a stop in another file refreshes totals across all files with stops", function()
    local fileA = vim.fn.tempname() .. "_a.lua"
    local fileB = vim.fn.tempname() .. "_b.lua"
    vim.fn.writefile({ "a1", "a2", "a3" }, fileA)
    vim.fn.writefile({ "b1", "b2", "b3" }, fileB)

    package.loaded["codetour.state"] = nil
    package.loaded["codetour.notes"] = nil
    package.loaded["codetour.anchor"] = nil
    state = require "codetour.state"
    require("codetour.config").merge { note_prefix = "({idx}/{total}) " }

    -- Two stops in file A
    vim.cmd("e " .. vim.fn.fnameescape(fileA))
    local bufA = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "first"
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    state.add "second"

    -- One stop in file B (split so file A stays loaded)
    vim.cmd("split " .. vim.fn.fnameescape(fileB))
    local bufB = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "in B"

    local NS = vim.api.nvim_create_namespace "codetour_notes"

    -- File A's virt_lines should now show (1/3) and (2/3), not the stale (1/2) and (2/2).
    local marksA = vim.api.nvim_buf_get_extmarks(bufA, NS, 0, -1, { details = true })
    assert.equals(2, #marksA, "fileA should still have 2 virt_lines")
    local textsA = {}
    for _, m in ipairs(marksA) do
      table.insert(textsA, m[4].virt_lines[1][1][1])
    end
    table.sort(textsA)
    assert.is_truthy(textsA[1]:match "%(1/3%)", "expected (1/3) in fileA, got: " .. textsA[1])
    assert.is_truthy(textsA[2]:match "%(2/3%)", "expected (2/3) in fileA, got: " .. textsA[2])

    -- File B should have exactly 1 virt_line, with no leakage from other files.
    local marksB = vim.api.nvim_buf_get_extmarks(bufB, NS, 0, -1, { details = true })
    assert.equals(1, #marksB, "fileB should have exactly 1 virt_line, no leakage")
    assert.is_truthy(marksB[1][4].virt_lines[1][1][1]:match "%(3/3%) in B")
  end)

  it("does not duplicate virt_lines when stops are added incrementally", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "line 1", "line 2", "line 3", "line 4", "line 5" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    local bufnr = vim.api.nvim_get_current_buf()

    package.loaded["codetour.state"] = nil
    package.loaded["codetour.notes"] = nil
    package.loaded["codetour.anchor"] = nil
    local state = require "codetour.state"

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "first"
    local NS = vim.api.nvim_create_namespace "codetour_notes"
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, {})
    assert.equals(1, #marks, "after first :TourAdd, expected 1 note extmark")

    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    state.add "second"
    marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, {})
    assert.equals(2, #marks, "after second :TourAdd, expected exactly 2 note extmarks (no duplicates)")
  end)

  it("add() refuses to create a duplicate stop at the same (file, lnum)", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "line 1", "line 2", "line 3" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    package.loaded["codetour.state"] = nil
    state = require "codetour.state"
    state.add "first"
    assert.equals(1, #state.data.stops)
    -- Same line, different note text → should still refuse
    state.add "second attempt"
    assert.equals(1, #state.data.stops, "duplicate at same lnum should be refused")
    assert.equals("first", state.data.stops[1].note)
  end)

  it("add() allows same lnum across different files", function()
    local tmp1 = vim.fn.tempname() .. ".lua"
    local tmp2 = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "line 1", "line 2" }, tmp1)
    vim.fn.writefile({ "line 1", "line 2" }, tmp2)

    package.loaded["codetour.state"] = nil
    state = require "codetour.state"

    vim.cmd("e " .. vim.fn.fnameescape(tmp1))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "in tmp1"

    vim.cmd("e " .. vim.fn.fnameescape(tmp2))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "in tmp2"

    assert.equals(2, #state.data.stops, "same lnum in different files should both be added")
  end)

  it("remove() drops the nearest stop and shifts remaining indices", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c", "d", "e" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))

    package.loaded["codetour.state"] = nil
    state = require "codetour.state"

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "first"
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    state.add "third"
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    state.add "fifth"
    assert.equals(3, #state.data.stops)

    -- Cursor near the middle stop
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    state.remove()
    assert.equals(2, #state.data.stops)
    assert.equals("first", state.data.stops[1].note)
    assert.equals("fifth", state.data.stops[2].note) -- index shifted down
  end)

  it("remove() bails when no stop is in the current buffer", function()
    package.loaded["codetour.state"] = nil
    state = require "codetour.state"
    vim.cmd "enew"
    state.data.stops = { { file = "/elsewhere/file.lua", lnum = 1, col = 0, note = "x", context = "" } }
    state.data.loaded = true
    state.remove()
    assert.equals(1, #state.data.stops, "no removal should occur")
  end)

  it("add() preserves the current quickfix index when syncing", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c", "d" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))

    package.loaded["codetour.state"] = nil
    state = require "codetour.state"

    -- Three stops, then prime a tour qf and move to entry 3
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "first"
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    state.add "second"
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    state.add "third"

    vim.fn.setqflist({}, " ", {
      title = "tour:test",
      items = {
        { filename = tmp, lnum = 1, col = 1, text = "first" },
        { filename = tmp, lnum = 2, col = 1, text = "second" },
        { filename = tmp, lnum = 3, col = 1, text = "third" },
      },
    })
    vim.fn.setqflist({}, "r", { nr = 0, idx = 3 })
    assert.equals(3, vim.fn.getqflist({ idx = 0 }).idx, "preflight: should be at idx 3")

    -- Add a fourth stop; the qf cursor should stay at entry 3
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    state.add "fourth"
    assert.equals(3, vim.fn.getqflist({ idx = 0 }).idx, "qf idx should be preserved at 3 after add")
  end)

  it("remove() clamps the quickfix index when items shrink past the saved position", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))

    package.loaded["codetour.state"] = nil
    state = require "codetour.state"

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "first"
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    state.add "second"

    vim.fn.setqflist({}, " ", {
      title = "tour:test",
      items = {
        { filename = tmp, lnum = 1, col = 1, text = "first" },
        { filename = tmp, lnum = 2, col = 1, text = "second" },
      },
    })
    vim.fn.setqflist({}, "r", { nr = 0, idx = 2 })

    -- Remove the second stop; qf shrinks to 1 item, idx should clamp to 1
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    state.remove()
    assert.equals(1, vim.fn.getqflist({ idx = 0 }).idx, "qf idx should clamp to last remaining item")
  end)

  it("add() updates the quickfix list when a tour is active", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c", "d" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))

    package.loaded["codetour.state"] = nil
    state = require "codetour.state"

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "first"
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    state.add "second"

    -- Simulate :TourOpen
    vim.fn.setqflist({}, " ", {
      title = "tour:test",
      items = {
        { filename = tmp, lnum = 1, col = 1, text = "first" },
        { filename = tmp, lnum = 2, col = 1, text = "second" },
      },
    })

    -- Add a third stop
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    state.add "third"

    -- qf should now have 3 items, not 2
    local items = vim.fn.getqflist()
    assert.equals(3, #items)
    assert.equals("third", items[3].text)
  end)

  it("create() empties the quickfix list when switching tours mid-tour", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))

    package.loaded["codetour.state"] = nil
    state = require "codetour.state"

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "first" -- auto-creates "default"

    vim.fn.setqflist({}, " ", {
      title = "tour:test",
      items = { { filename = tmp, lnum = 1, col = 1, text = "first" } },
    })

    state.create "fresh" -- new empty tour, becomes active

    local items = vim.fn.getqflist()
    assert.equals(0, #items, "tour qf should be emptied after creating a new tour")
  end)

  it("remove() updates the quickfix list when a tour is active", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))

    package.loaded["codetour.state"] = nil
    state = require "codetour.state"

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "first"
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    state.add "second"

    -- Simulate :TourOpen
    vim.fn.setqflist({}, " ", {
      title = "tour:test",
      items = {
        { filename = tmp, lnum = 1, col = 1, text = "first" },
        { filename = tmp, lnum = 2, col = 1, text = "second" },
      },
    })

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.remove() -- removes "first"

    local items = vim.fn.getqflist()
    assert.equals(1, #items)
    assert.equals("second", items[1].text)
  end)

  it("edit_note() leaves a non-tour quickfix list alone", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "line 1" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    state.data.stops = { { file = tmp, lnum = 1, col = 0, note = "old", context = "" } }
    state.data.loaded = true

    -- Pretend the user has a :grep result up
    vim.fn.setqflist({}, " ", {
      title = "[grep] foo",
      items = { { filename = tmp, lnum = 1, col = 1, text = "grep hit" } },
    })

    state.edit_note "new note"

    local items = vim.fn.getqflist()
    assert.equals("grep hit", items[1].text) -- untouched
  end)
end)
