local git = require "codetour.git"
local storage = require "codetour.storage"
local Tour = require "codetour.tour"

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

  it("returns root and branch inside a repo on main", function()
    local d = tmpdir()
    init_git_repo(d)
    vim.cmd("cd " .. vim.fn.fnameescape(d))
    local info = git.info()
    assert.is_not_nil(info)
    assert.equals("main", info.branch)
    assert.is_not_nil(info.root)
  end)

  it("preserves branch names with / verbatim (sanitization happens at the storage layer)", function()
    local d = tmpdir()
    init_git_repo(d)
    vim.cmd("cd " .. vim.fn.fnameescape(d))
    vim.fn.system { "git", "-C", d, "checkout", "-q", "-b", "feature/foo" }
    local info = git.info()
    assert.equals("feature/foo", info.branch)
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
    -- Defensive: every test should leave storage_path back at the default,
    -- otherwise a failure mid-test pollutes everything downstream.
    require("codetour.config").merge { storage_path = ".codetour" }
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end)

  it("load_tour returns nil when no tour file exists", function()
    assert.is_nil(storage.load_tour "missing")
  end)

  it("list_tours returns empty when no tours exist", function()
    assert.equals(0, #storage.list_tours())
  end)

  it("save_tour + load_tour round-trips an empty tour", function()
    storage.save_tour(Tour.new "default")
    local loaded = storage.load_tour "default"
    assert.is_not_nil(loaded)
    assert.equals("default", loaded.name)
    assert.equals(0, #loaded.stops)
  end)

  it("converts absolute paths to relative on save and back on load", function()
    local info = git.info()
    local tour = Tour.new "auth"
    tour.stops = {
      { file = info.root .. "/foo.lua", lnum = 10, col = 0, note = "entry" },
      { file = info.root .. "/bar/baz.py", lnum = 42, col = 4, note = "" },
    }
    storage.save_tour(tour)

    -- On-disk uses relative paths
    local on_disk = info.root .. "/.codetour/auth.json"
    local f = io.open(on_disk, "r")
    local raw = f:read "*a"
    f:close()
    local decoded = vim.fn.json_decode(raw)
    assert.equals("auth", decoded.name)
    assert.equals("foo.lua", decoded.stops[1].file)
    assert.equals("bar/baz.py", decoded.stops[2].file)

    -- Load reconstructs absolute paths
    local loaded = storage.load_tour "auth"
    assert.equals(info.root .. "/foo.lua", loaded.stops[1].file)
    assert.equals(10, loaded.stops[1].lnum)
    assert.equals("entry", loaded.stops[1].note)
  end)

  it("load_tour returns nil on malformed JSON", function()
    local info = git.info()
    local file = info.root .. "/.codetour/auth.json"
    vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
    local f = io.open(file, "w")
    f:write "garbage{{{"
    f:close()
    assert.is_nil(storage.load_tour "auth")
  end)

  it("active-tour pointer round-trips", function()
    assert.is_nil(storage.read_active())
    storage.write_active "auth"
    assert.equals("auth", storage.read_active())
    storage.write_active(nil)
    assert.is_nil(storage.read_active())
  end)

  it("delete removes the tour file", function()
    storage.save_tour(Tour.new "doomed")
    assert.is_not_nil(storage.load_tour "doomed")
    assert.is_true(storage.delete "doomed")
    assert.is_nil(storage.load_tour "doomed")
  end)

  it("respects setup{ storage_path } as a relative path inside the git root", function()
    require("codetour.config").merge { storage_path = "my-tours" }
    storage.save_tour(Tour.new "scratch")
    local info = require("codetour.git").info()
    assert.equals(1, vim.fn.filereadable(info.root .. "/my-tours/scratch.json"))
  end)

  it("respects setup{ storage_path } as an absolute path (works without a git repo)", function()
    local outside = vim.fn.tempname() .. "_tours"
    require("codetour.config").merge { storage_path = outside }
    -- cd to a non-repo dir to confirm we don't need git here
    vim.cmd("cd " .. vim.fn.fnameescape "/tmp")
    storage.save_tour(Tour.new "scratch")
    assert.equals(1, vim.fn.filereadable(outside .. "/scratch.json"))
  end)

  it("list_tours sorts and excludes the _active_tour pointer", function()
    storage.save_tour(Tour.new "billing")
    storage.save_tour(Tour.new "auth")
    storage.write_active "auth"
    local tours = storage.list_tours()
    assert.same({ "auth", "billing" }, tours)
  end)

  it("save_tour + load_tour round-trips stop ids and next_id", function()
    local info = git.info()
    local tour = Tour.new "auth"
    Tour.add_stop(tour, { file = info.root .. "/a.lua", lnum = 1, col = 0, note = "one", context = "" })
    Tour.add_stop(tour, { file = info.root .. "/b.lua", lnum = 1, col = 0, note = "two", context = "" })
    assert.equals(1, tour.stops[1].id)
    assert.equals(2, tour.stops[2].id)
    assert.equals(3, tour.next_id)
    storage.save_tour(tour)

    local loaded = storage.load_tour "auth"
    assert.equals(1, loaded.stops[1].id, "stop ids must survive a save+load round-trip")
    assert.equals(2, loaded.stops[2].id)
    assert.equals(3, loaded.next_id, "tour.next_id must survive too")
  end)

  it("load_tour synthesises ids for legacy stop entries that lack them", function()
    -- Hand-craft an old-format tour JSON (no ids on stops, no next_id field).
    local info = git.info()
    local file = info.root .. "/.codetour/legacy.json"
    vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
    local f = io.open(file, "w")
    f:write(vim.fn.json_encode {
      version = 2,
      name = "legacy",
      stops = {
        { file = "a.lua", lnum = 1, col = 0, note = "x", context = "" },
        { file = "b.lua", lnum = 1, col = 0, note = "y", context = "" },
      },
    })
    f:close()

    local loaded = storage.load_tour "legacy"
    assert.is_not_nil(loaded.stops[1].id, "legacy stop should have an id synthesised")
    assert.is_not_nil(loaded.stops[2].id)
    assert.are_not.equals(loaded.stops[1].id, loaded.stops[2].id, "synthesised ids must be unique")
    assert.is_true(loaded.next_id > loaded.stops[1].id and loaded.next_id > loaded.stops[2].id)
  end)

  it("load_tour advances next_id past the highest stored stop.id (defensive)", function()
    -- Simulates a JSON written with stale next_id (e.g. user edited it down).
    local info = git.info()
    local file = info.root .. "/.codetour/stale.json"
    vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
    local f = io.open(file, "w")
    f:write(vim.fn.json_encode {
      version = 2,
      name = "stale",
      next_id = 2, -- bogus: lower than max(id) below
      stops = {
        { id = 7, file = "a.lua", lnum = 1, col = 0, note = "x", context = "" },
      },
    })
    f:close()

    local loaded = storage.load_tour "stale"
    assert.equals(8, loaded.next_id, "next_id must be > max stop.id even if JSON says otherwise")
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

describe("codetour.tour", function()
  local Tour

  before_each(function()
    package.loaded["codetour.tour"] = nil
    Tour = require "codetour.tour"
  end)

  it("new() creates a tour with a name and an empty stops list", function()
    local t = Tour.new "auth"
    assert.equals("auth", t.name)
    assert.equals(0, #t.stops)
  end)

  it("add_stop() appends a stop and returns ok", function()
    local t = Tour.new "auth"
    local ok = Tour.add_stop(t, { file = "/abs/foo.lua", lnum = 10, col = 0, note = "entry", context = "" })
    assert.is_true(ok)
    assert.equals(1, #t.stops)
    assert.equals("entry", t.stops[1].note)
  end)

  it("add_stop() refuses a duplicate (file, lnum)", function()
    local t = Tour.new "auth"
    Tour.add_stop(t, { file = "/abs/foo.lua", lnum = 10, col = 0, note = "first", context = "" })
    local ok, err = Tour.add_stop(t, { file = "/abs/foo.lua", lnum = 10, col = 0, note = "second", context = "" })
    assert.is_false(ok)
    assert.is_truthy(err:match "already exists")
    assert.equals(1, #t.stops)
    assert.equals("first", t.stops[1].note)
  end)

  it("add_stop() allows the same lnum in different files", function()
    local t = Tour.new "auth"
    Tour.add_stop(t, { file = "/abs/foo.lua", lnum = 10, col = 0, note = "in foo", context = "" })
    local ok = Tour.add_stop(t, { file = "/abs/bar.lua", lnum = 10, col = 0, note = "in bar", context = "" })
    assert.is_true(ok)
    assert.equals(2, #t.stops)
  end)

  it("remove_stop() drops the stop at idx and returns it", function()
    local t = Tour.new "auth"
    Tour.add_stop(t, { file = "/a", lnum = 1, col = 0, note = "first", context = "" })
    Tour.add_stop(t, { file = "/b", lnum = 1, col = 0, note = "second", context = "" })
    local removed, err = Tour.remove_stop(t, 1)
    assert.is_nil(err)
    assert.equals("first", removed.note)
    assert.equals(1, #t.stops)
    assert.equals("second", t.stops[1].note)
  end)

  it("remove_stop() errors on out-of-range idx", function()
    local t = Tour.new "auth"
    Tour.add_stop(t, { file = "/a", lnum = 1, col = 0, note = "only", context = "" })
    local removed, err = Tour.remove_stop(t, 5)
    assert.is_nil(removed)
    assert.is_truthy(err:match "doesn't exist")
    assert.equals(1, #t.stops)
  end)

  it("remove_stop() errors on nil idx", function()
    local t = Tour.new "auth"
    local removed, err = Tour.remove_stop(t, nil)
    assert.is_nil(removed)
    assert.is_truthy(err)
  end)

  it("update_note() replaces the note text", function()
    local t = Tour.new "auth"
    Tour.add_stop(t, { file = "/a", lnum = 1, col = 0, note = "old", context = "" })
    local ok = Tour.update_note(t, 1, "new")
    assert.is_true(ok)
    assert.equals("new", t.stops[1].note)
  end)

  it("update_note() errors on out-of-range idx", function()
    local t = Tour.new "auth"
    local ok, err = Tour.update_note(t, 1, "x")
    assert.is_false(ok)
    assert.is_truthy(err)
  end)

  it("update_note() with nil text coerces to empty string", function()
    -- Tour itself accepts empty/nil text; rejection of empty input is a
    -- state.lua / user-input concern, not a Tour invariant.
    local t = Tour.new "auth"
    Tour.add_stop(t, { file = "/a", lnum = 1, col = 0, note = "before", context = "" })
    Tour.update_note(t, 1, nil)
    assert.equals("", t.stops[1].note)
  end)

  it("replace_stops() swaps the entire list", function()
    local t = Tour.new "auth"
    Tour.add_stop(t, { file = "/a", lnum = 1, col = 0, note = "one", context = "" })
    Tour.add_stop(t, { file = "/b", lnum = 1, col = 0, note = "two", context = "" })
    local ok = Tour.replace_stops(t, {
      { file = "/c", lnum = 1, col = 0, note = "three", context = "" },
    })
    assert.is_true(ok)
    assert.equals(1, #t.stops)
    assert.equals("three", t.stops[1].note)
  end)

  it("replace_stops() allows an empty list", function()
    local t = Tour.new "auth"
    Tour.add_stop(t, { file = "/a", lnum = 1, col = 0, note = "x", context = "" })
    local ok = Tour.replace_stops(t, {})
    assert.is_true(ok)
    assert.equals(0, #t.stops)
  end)

  it("replace_stops() refuses duplicate (file, lnum) entries in the new list", function()
    local t = Tour.new "auth"
    local ok, err = Tour.replace_stops(t, {
      { file = "/a", lnum = 1, col = 0, note = "one", context = "" },
      { file = "/a", lnum = 1, col = 0, note = "two", context = "" },
    })
    assert.is_false(ok)
    assert.is_truthy(err:match "duplicate")
    -- Original (empty) list left intact since validation failed
    assert.equals(0, #t.stops)
  end)

  it("has_stop_at() finds a matching (file, lnum) pair", function()
    local t = Tour.new "auth"
    Tour.add_stop(t, { file = "/a", lnum = 3, col = 0, note = "x", context = "" })
    assert.is_true(Tour.has_stop_at(t, "/a", 3))
    assert.is_false(Tour.has_stop_at(t, "/a", 4))
    assert.is_false(Tour.has_stop_at(t, "/b", 3))
  end)

  it("nearest_stop_idx() returns the closest stop by lnum in the same file", function()
    local t = Tour.new "auth"
    Tour.add_stop(t, { file = "/a", lnum = 5, col = 0, note = "first", context = "" })
    Tour.add_stop(t, { file = "/a", lnum = 15, col = 0, note = "second", context = "" })
    Tour.add_stop(t, { file = "/b", lnum = 7, col = 0, note = "other file", context = "" })
    -- Cursor at lnum 7 in /a: stop #1 (lnum 5, dist 2) beats #2 (lnum 15, dist 8)
    assert.equals(1, Tour.nearest_stop_idx(t, "/a", 7))
    -- Cursor at lnum 12 in /a: stop #2 (lnum 15, dist 3) beats #1 (lnum 5, dist 7)
    assert.equals(2, Tour.nearest_stop_idx(t, "/a", 12))
  end)

  it("nearest_stop_idx() returns nil when no stop lives in this file", function()
    local t = Tour.new "auth"
    Tour.add_stop(t, { file = "/a", lnum = 1, col = 0, note = "x", context = "" })
    assert.is_nil(Tour.nearest_stop_idx(t, "/b", 1))
  end)

  it("adjacent_stop() walks stops in the same file sorted by lnum", function()
    local t = Tour.new "auth"
    -- Added out of order to verify the sort is by lnum, not insertion order.
    Tour.add_stop(t, { file = "/a", lnum = 5, col = 0, note = "middle", context = "" })
    Tour.add_stop(t, { file = "/a", lnum = 2, col = 0, note = "first", context = "" })
    Tour.add_stop(t, { file = "/a", lnum = 8, col = 0, note = "last", context = "" })

    assert.equals("middle", Tour.adjacent_stop(t, "/a", 2, "next").note)
    assert.equals("last", Tour.adjacent_stop(t, "/a", 5, "next").note)
    assert.is_nil(Tour.adjacent_stop(t, "/a", 8, "next"))

    assert.equals("middle", Tour.adjacent_stop(t, "/a", 8, "prev").note)
    assert.equals("first", Tour.adjacent_stop(t, "/a", 5, "prev").note)
    assert.is_nil(Tour.adjacent_stop(t, "/a", 2, "prev"))
  end)

  it("adjacent_stop() ignores stops in other files", function()
    local t = Tour.new "auth"
    Tour.add_stop(t, { file = "/a", lnum = 1, col = 0, note = "in a", context = "" })
    Tour.add_stop(t, { file = "/b", lnum = 10, col = 0, note = "in b", context = "" })
    -- Nothing in /a beyond lnum 5 — /b's lnum 10 doesn't count.
    assert.is_nil(Tour.adjacent_stop(t, "/a", 5, "next"))
  end)

  it("new() initialises next_id to 1", function()
    local t = Tour.new "auth"
    assert.equals(1, t.next_id)
  end)

  it("add_stop() assigns sequential ids and bumps next_id", function()
    local t = Tour.new "auth"
    Tour.add_stop(t, { file = "/a", lnum = 1, col = 0, note = "first", context = "" })
    Tour.add_stop(t, { file = "/b", lnum = 1, col = 0, note = "second", context = "" })
    assert.equals(1, t.stops[1].id)
    assert.equals(2, t.stops[2].id)
    assert.equals(3, t.next_id)
  end)

  it("add_stop() overwrites any caller-supplied id (no caller-controlled identity)", function()
    local t = Tour.new "auth"
    Tour.add_stop(t, { id = 999, file = "/a", lnum = 1, col = 0, note = "x", context = "" })
    assert.equals(1, t.stops[1].id, "caller's id=999 should have been replaced with 1")
  end)

  it("remove_stop() does not roll back next_id (so re-adds cannot collide)", function()
    local t = Tour.new "auth"
    Tour.add_stop(t, { file = "/a", lnum = 1, col = 0, note = "one", context = "" }) -- id 1
    Tour.add_stop(t, { file = "/b", lnum = 1, col = 0, note = "two", context = "" }) -- id 2
    Tour.remove_stop(t, 2)
    assert.equals(3, t.next_id, "next_id stays past the highest id ever assigned")
    Tour.add_stop(t, { file = "/c", lnum = 1, col = 0, note = "three", context = "" })
    assert.equals(3, t.stops[2].id, "new stop gets fresh id 3, not the recycled 2")
  end)

  it("replace_stops() preserves stops' existing ids", function()
    local t = Tour.new "auth"
    Tour.add_stop(t, { file = "/a", lnum = 1, col = 0, note = "one", context = "" }) -- id 1
    Tour.add_stop(t, { file = "/b", lnum = 1, col = 0, note = "two", context = "" }) -- id 2

    -- Reorder: keep both ids
    local reordered = { t.stops[2], t.stops[1] }
    Tour.replace_stops(t, reordered)
    assert.equals(2, t.stops[1].id)
    assert.equals(1, t.stops[2].id)
  end)

  it("replace_stops() assigns ids to entries that lack them", function()
    local t = Tour.new "auth"
    Tour.add_stop(t, { file = "/a", lnum = 1, col = 0, note = "one", context = "" }) -- id 1
    Tour.replace_stops(t, {
      t.stops[1], -- carries id 1
      { file = "/b", lnum = 1, col = 0, note = "no id", context = "" }, -- gets id 2
    })
    assert.equals(1, t.stops[1].id)
    assert.equals(2, t.stops[2].id)
    assert.equals(3, t.next_id)
  end)

  it("replace_stops() advances next_id past caller-supplied ids that exceed it", function()
    local t = Tour.new "auth"
    Tour.replace_stops(t, {
      { id = 42, file = "/a", lnum = 1, col = 0, note = "loaded from disk", context = "" },
    })
    assert.equals(43, t.next_id)
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

  it("detect_drift_offline() updates stop.lnum when the file drifted on disk", function()
    -- Write a file with a known context line at position 5.
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({
      "old line 1",
      "old line 2",
      "old line 3",
      "old line 4",
      "function dispatch(args)",
      "old line 6",
    }, tmp)

    local stop = { file = tmp, lnum = 5, col = 0, note = "", context = "function dispatch(args)" }

    -- Without touching the file, offline drift detection should be a no-op
    -- (context still matches at line 5).
    anchor.detect_drift_offline(stop)
    assert.equals(5, stop.lnum, "no drift expected when file is unchanged")

    -- Now prepend 2 lines on disk; the context line moves to line 7.
    vim.fn.writefile({
      "NEW line A",
      "NEW line B",
      "old line 1",
      "old line 2",
      "old line 3",
      "old line 4",
      "function dispatch(args)",
      "old line 6",
    }, tmp)

    anchor.detect_drift_offline(stop)
    assert.equals(7, stop.lnum, "offline drift should re-anchor to the new line")
  end)

  it("detect_drift_offline() is a no-op when the file is missing or has no context", function()
    -- Missing file
    local stop1 = { file = "/nonexistent/path.lua", lnum = 5, col = 0, note = "", context = "anything" }
    anchor.detect_drift_offline(stop1)
    assert.equals(5, stop1.lnum, "missing file: lnum unchanged")

    -- No context to search for
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c" }, tmp)
    local stop2 = { file = tmp, lnum = 2, col = 0, note = "", context = "" }
    anchor.detect_drift_offline(stop2)
    assert.equals(2, stop2.lnum, "empty context: lnum unchanged (we'd have nothing to search for)")
  end)

  it("detect_drift_offline() leaves lnum alone when context cannot be found anywhere", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "totally", "unrelated", "content" }, tmp)
    local stop = { file = tmp, lnum = 2, col = 0, note = "", context = "function dispatch(args)" }
    anchor.detect_drift_offline(stop)
    assert.equals(2, stop.lnum, "no context match: stop stays at its persisted lnum")
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

describe("codetour.edit", function()
  local edit
  local original_cwd
  local repo

  before_each(function()
    original_cwd = vim.fn.getcwd()
    repo = tmpdir()
    init_git_repo(repo)
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    package.loaded["codetour.edit"] = nil
    package.loaded["codetour.state"] = nil
    package.loaded["codetour.anchor"] = nil
    package.loaded["codetour.notes"] = nil
    package.loaded["codetour.signs"] = nil
    edit = require "codetour.edit"
  end)
  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end)

  it("render() formats stops with the [N] file:lnum ─ note shape", function()
    local stops = {
      { file = "/abs/foo.lua", lnum = 10, col = 0, note = "entry", context = "" },
      { file = "/abs/bar.lua", lnum = 25, col = 0, note = "dispatch", context = "" },
    }
    local lines = edit.render(stops)
    assert.equals(2, #lines)
    assert.is_truthy(lines[1]:match "^%[1%]")
    assert.is_truthy(lines[1]:match "foo%.lua:10")
    assert.is_truthy(lines[1]:match "─%s+entry$")
    assert.is_truthy(lines[2]:match "^%[2%]")
    assert.is_truthy(lines[2]:match "─%s+dispatch$")
  end)

  it("parse() round-trips a render() output", function()
    local stops = {
      { file = "/abs/foo.lua", lnum = 10, col = 0, note = "entry", context = "" },
      { file = "/abs/bar.lua", lnum = 25, col = 0, note = "dispatch handler", context = "" },
    }
    local parsed, err = edit.parse(edit.render(stops))
    assert.is_nil(err)
    assert.equals(2, #parsed)
    assert.equals(1, parsed[1].idx)
    assert.equals("entry", parsed[1].note)
    assert.equals(2, parsed[2].idx)
    assert.equals("dispatch handler", parsed[2].note)
  end)

  it("parse() captures edited notes", function()
    local lines = {
      "[1]  foo.lua:10  ─  rewritten note text",
      "[2]  bar.lua:25  ─  another rewrite",
    }
    local parsed = edit.parse(lines)
    assert.equals("rewritten note text", parsed[1].note)
    assert.equals("another rewrite", parsed[2].note)
  end)

  it("parse() captures reordering by reading lines in order", function()
    local lines = {
      "[3]  c.lua:1  ─  third",
      "[1]  a.lua:1  ─  first",
      "[2]  b.lua:1  ─  second",
    }
    local parsed = edit.parse(lines)
    -- Order in parsed = order in buffer = new tour order
    assert.equals(3, parsed[1].idx)
    assert.equals(1, parsed[2].idx)
    assert.equals(2, parsed[3].idx)
  end)

  it("parse() skips header comment lines (those starting with #)", function()
    local lines = {
      "# codetour ─ tour: auth  ·  2 stop(s)",
      "# <CR> jump  •  :w apply  •  q close",
      "",
      "[1]  foo.lua:10  ─  first",
      "[2]  bar.lua:25  ─  second",
    }
    local parsed, err = edit.parse(lines)
    assert.is_nil(err)
    assert.equals(2, #parsed)
    assert.equals("first", parsed[1].note)
    assert.equals("second", parsed[2].note)
  end)

  it("_first_stop_lineno skips past the header to the first stop", function()
    local lines = {
      "# codetour ─ tour: auth  ·  2 stop(s)",
      "# <CR> jump  •  :w apply  •  q close",
      "",
      "[1]  foo.lua:10  ─  first",
      "[2]  bar.lua:25  ─  second",
    }
    assert.equals(4, edit._first_stop_lineno(lines))
  end)

  it("parse() skips blank lines", function()
    local lines = {
      "[1]  foo.lua:10  ─  first",
      "",
      "  ",
      "[2]  bar.lua:25  ─  second",
    }
    local parsed = edit.parse(lines)
    assert.equals(2, #parsed)
  end)

  it("parse() returns an error for malformed lines", function()
    local lines = {
      "[1]  foo.lua:10  ─  first",
      "this is not a valid stop line",
      "[2]  bar.lua:25  ─  second",
    }
    local parsed, err = edit.parse(lines)
    assert.is_nil(parsed)
    assert.is_truthy(err:match "line 2"):match "malformed"
  end)

  it("apply() refuses when the same stop appears twice", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    local state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "first"
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    state.add "second"

    local ok, err = edit.apply { { idx = 1, note = "x" }, { idx = 1, note = "y" } }
    assert.is_false(ok)
    assert.is_truthy(err:match "more than once")
    -- State unchanged
    assert.equals(2, #state.data.active_tour.stops)
    assert.equals("first", state.data.active_tour.stops[1].note)
  end)

  it("apply() refuses when an index doesn't exist", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    local state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "only"

    local ok, err = edit.apply { { idx = 99, note = "x" } }
    assert.is_false(ok)
    assert.is_truthy(err:match "doesn't exist")
    assert.equals(1, #state.data.active_tour.stops)
  end)

  it("apply() reorders, edits notes, and removes stops atomically", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    local state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "alpha"
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    state.add "beta"
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    state.add "gamma"

    -- Reorder (3 → 1 → 2), edit beta's note, drop nothing
    local ok = edit.apply {
      { idx = 3, note = "GAMMA edited" },
      { idx = 1, note = "alpha" },
      { idx = 2, note = "BETA edited" },
    }
    assert.is_true(ok)
    assert.equals(3, #state.data.active_tour.stops)
    assert.equals("GAMMA edited", state.data.active_tour.stops[1].note)
    assert.equals("alpha", state.data.active_tour.stops[2].note)
    assert.equals("BETA edited", state.data.active_tour.stops[3].note)
  end)

  it("apply() preserves file/lnum/col/context (only note is editable)", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    local state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "original"

    local original_file = state.data.active_tour.stops[1].file
    local original_lnum = state.data.active_tour.stops[1].lnum
    local original_context = state.data.active_tour.stops[1].context

    edit.apply { { idx = 1, note = "rewritten" } }

    assert.equals(original_file, state.data.active_tour.stops[1].file)
    assert.equals(original_lnum, state.data.active_tour.stops[1].lnum)
    assert.equals(original_context, state.data.active_tour.stops[1].context)
    assert.equals("rewritten", state.data.active_tour.stops[1].note)
  end)

  it("open() warns and bails when no tour is open", function()
    local original = vim.notify
    local captured
    vim.notify = function(msg, level)
      captured = { msg = msg, level = level }
    end
    edit.open()
    vim.notify = original
    assert.is_truthy(captured.msg:match "no tour is open")
    -- No list/preview windows created
    assert.is_nil(edit._state.list_winid)
  end)

  it("open() then close() leaves no leftover windows or buffers", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    local state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "smoke"

    edit.open()
    assert.is_not_nil(edit._state.list_winid)
    assert.is_not_nil(edit._state.preview_winid)
    local list_buf = edit._state.list_bufnr

    edit.close()
    -- After close: state cleared
    assert.is_nil(edit._state.list_winid)
    assert.is_nil(edit._state.list_bufnr)
    -- And the list buffer is wiped
    assert.is_false(vim.api.nvim_buf_is_valid(list_buf))
  end)

  it("commit() short-circuits on parse error before mutating state", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    local state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "untouched"

    local ok, err = edit.commit { "not-a-valid-line" }
    assert.is_false(ok)
    assert.is_truthy(err)
    assert.equals("untouched", state.data.active_tour.stops[1].note)
  end)

  -- UI lifecycle: drive the autocmd-bound handlers (_on_save, _on_enter,
  -- _update_preview) directly rather than feedkeys-ing <CR>/`:w` which is
  -- flaky under headless plenary. The handlers are wired into BufWriteCmd /
  -- CursorMoved / the <CR> mapping in production; here we invoke them in
  -- the same context (list buffer focused, _state populated).

  local function setup_tour_with_stops(...)
    local notes = { ... }
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c", "d", "e" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    local state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add
    for i, note in ipairs(notes) do
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      state.add(note)
    end
    return tmp, state
  end

  it("_on_save commits inline note edits to the active tour", function()
    local tmp, state = setup_tour_with_stops("first", "second")
    edit.open()

    -- Find the line in the list buffer for stop #1 and rewrite its note text.
    local lines = vim.api.nvim_buf_get_lines(edit._state.list_bufnr, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:match "^%[1%]" then
        local rewritten = line:gsub("─%s+first", "─ REWRITTEN")
        vim.api.nvim_buf_set_lines(edit._state.list_bufnr, i - 1, i, false, { rewritten })
        break
      end
    end
    vim.bo[edit._state.list_bufnr].modified = true

    edit._on_save()

    assert.equals("REWRITTEN", state.data.active_tour.stops[1].note)
    assert.equals("second", state.data.active_tour.stops[2].note, "other stop must be unchanged")
    assert.is_false(vim.bo[edit._state.list_bufnr].modified, "modified flag should clear after successful save")

    edit.close()
    _ = tmp
  end)

  it("_on_save leaves the buffer modified when parse fails", function()
    local _, state = setup_tour_with_stops "only"
    edit.open()

    -- Insert a malformed line into the buffer so the parser will reject it.
    vim.api.nvim_buf_set_lines(edit._state.list_bufnr, -1, -1, false, { "garbage line" })
    vim.bo[edit._state.list_bufnr].modified = true

    edit._on_save()

    assert.is_true(vim.bo[edit._state.list_bufnr].modified, "modified should persist on parse error")
    assert.equals("only", state.data.active_tour.stops[1].note, "state unchanged on parse error")

    edit.close()
  end)

  it("_on_enter jumps prev_winid to the stop's file + lnum", function()
    local tmp = setup_tour_with_stops("first", "second", "third")
    local origin_winid = vim.api.nvim_get_current_win()
    edit.open()

    -- Move cursor in the list buffer to the line for stop #2.
    local lines = vim.api.nvim_buf_get_lines(edit._state.list_bufnr, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:match "^%[2%]" then
        vim.api.nvim_win_set_cursor(edit._state.list_winid, { i, 0 })
        break
      end
    end

    edit._on_enter()

    -- After _on_enter, prev_winid (origin) should be focused on tmp at lnum 2.
    -- Stops carry canonical paths (state.add canonicalises on insert), and
    -- nvim_buf_get_name returns whatever the buffer was :edit-ed with — also
    -- canonical here since `state.add → state.add → Tour.add_stop` round-trips
    -- through the canonical filename. Compare via util.canonical to handle
    -- /tmp vs /private/tmp on macOS.
    local util = require "codetour.util"
    assert.equals(origin_winid, vim.api.nvim_get_current_win())
    assert.equals(util.canonical(tmp), util.canonical(vim.api.nvim_buf_get_name(0)))
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("_on_enter refuses when the list buffer has unsaved edits", function()
    local _ = setup_tour_with_stops "only"
    edit.open()
    local list_buf = edit._state.list_bufnr
    local list_win = edit._state.list_winid

    -- Mark the buffer modified without changing anything semantic.
    vim.bo[list_buf].modified = true

    -- Capture the warning we expect _on_enter to emit.
    local captured
    local original_notify = vim.notify
    vim.notify = function(msg, _)
      captured = msg
    end

    edit._on_enter()

    vim.notify = original_notify
    assert.is_truthy(captured and captured:match "unsaved edits")
    -- UI should still be up (no close on refuse).
    assert.is_true(vim.api.nvim_win_is_valid(list_win), "list window must still be open")
    assert.equals(list_win, vim.api.nvim_get_current_win())

    edit.close()
  end)

  it("_update_preview points the preview window at the stop's file", function()
    local tmpA = vim.fn.tempname() .. "_a.lua"
    local tmpB = vim.fn.tempname() .. "_b.lua"
    vim.fn.writefile({ "alpha 1", "alpha 2", "alpha 3" }, tmpA)
    vim.fn.writefile({ "beta 1", "beta 2", "beta 3" }, tmpB)

    vim.cmd("e " .. vim.fn.fnameescape(tmpA))
    local state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "in A"
    vim.cmd("e " .. vim.fn.fnameescape(tmpB))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    state.add "in B"

    edit.open()

    -- Move cursor to stop #2 (file B) in the list buffer and fire _update_preview.
    local lines = vim.api.nvim_buf_get_lines(edit._state.list_bufnr, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:match "^%[2%]" then
        vim.api.nvim_win_set_cursor(edit._state.list_winid, { i, 0 })
        break
      end
    end
    edit._update_preview()

    local preview_lines = vim.api.nvim_buf_get_lines(edit._state.preview_bufnr, 0, -1, false)
    assert.equals("beta 1", preview_lines[1], "preview must show file B's content")
    assert.equals(2, vim.api.nvim_win_get_cursor(edit._state.preview_winid)[1], "preview cursor on stop's lnum")

    edit.close()
  end)

  it("close() tears down list buf and clears _state cleanly", function()
    local _ = setup_tour_with_stops "stop"
    edit.open()
    local list_buf = edit._state.list_bufnr
    assert.is_not_nil(edit._state.augroup)
    assert.is_not_nil(edit._state.list_winid)
    assert.is_not_nil(edit._state.preview_winid)

    edit.close()

    -- _state cleared: BufWipeout fires cleanup_state which nils every field.
    assert.is_nil(edit._state.list_bufnr)
    assert.is_nil(edit._state.list_winid)
    assert.is_nil(edit._state.preview_winid)
    assert.is_nil(edit._state.augroup)
    -- The list buffer was wiped. (Window validity is nvim-internal: when a
    -- wiped buffer was displayed, nvim replaces it with an unnamed buffer
    -- in that window rather than closing the window outright.)
    assert.is_false(vim.api.nvim_buf_is_valid(list_buf))
  end)
end)

describe("codetour.signs", function()
  local signs
  local anchor

  before_each(function()
    package.loaded["codetour.signs"] = nil
    package.loaded["codetour.anchor"] = nil
    signs = require "codetour.signs"
    anchor = require "codetour.anchor"
    -- Force enabled in case a prior test mutated config
    require("codetour.config").merge { signs = { enabled = true, text = nil, highlight = "Special" } }
  end)
  after_each(function()
    signs.detach_all()
    anchor.detach_all()
  end)

  local function buffer_with_lines(lines)
    local tmp = vim.fn.tempname()
    vim.fn.writefile(lines, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    return vim.api.nvim_get_current_buf(), tmp
  end

  it("refresh() places a sign per stop with the stop's index as the sign text", function()
    local bufnr, file = buffer_with_lines { "a", "b", "c" }
    local stops = {
      { file = file, lnum = 1, col = 0, note = "", context = "" },
      { file = file, lnum = 3, col = 0, note = "", context = "" },
    }
    -- Disable prefix for this test so we assert on the raw index.
    -- (merge with nil is a no-op due to tbl_deep_extend semantics; "" is the
    -- in-band signal for "no prefix" in sign_text_for.)
    require("codetour.config").merge { signs = { prefix = "" } }
    anchor.attach(bufnr, stops)
    signs.refresh(bufnr, stops)

    local NS = vim.api.nvim_create_namespace "codetour_signs"
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
    assert.equals(2, #marks)
    local at = {}
    for _, m in ipairs(marks) do
      at[m[2]] = m[4].sign_text
    end
    assert.equals("1", (at[0]:gsub("%s", "")))
    assert.equals("2", (at[2]:gsub("%s", ""))) -- parens drop gsub's count return
  end)

  it("refresh() prepends signs.prefix for single-digit indices", function()
    local bufnr, file = buffer_with_lines { "a", "b" }
    local stops = { { file = file, lnum = 1, col = 0, note = "", context = "" } }
    require("codetour.config").merge { signs = { prefix = "▸" } }
    anchor.attach(bufnr, stops)
    signs.refresh(bufnr, stops)

    local NS = vim.api.nvim_create_namespace "codetour_signs"
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
    assert.equals("▸1", (marks[1][4].sign_text:gsub("%s", "")))
    require("codetour.config").merge { signs = { prefix = "" } }
  end)

  it("refresh() drops the prefix for two-digit indices (sign_text is 2-cell capped)", function()
    -- Make a stop list with 10 entries; only the 10th is in this buffer
    local bufnr, file = buffer_with_lines { "x" }
    local stops = {}
    for i = 1, 9 do
      table.insert(stops, { file = "/nowhere", lnum = i, col = 0, note = "", context = "" })
    end
    table.insert(stops, { file = file, lnum = 1, col = 0, note = "", context = "" })

    require("codetour.config").merge { signs = { prefix = "▸" } }
    anchor.attach(bufnr, stops)
    signs.refresh(bufnr, stops)

    local NS = vim.api.nvim_create_namespace "codetour_signs"
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
    assert.equals("10", (marks[1][4].sign_text:gsub("%s", "")))
    require("codetour.config").merge { signs = { prefix = "" } }
  end)

  it("refresh() honours the configured fixed text override", function()
    local bufnr, file = buffer_with_lines { "a", "b" }
    local stops = { { file = file, lnum = 1, col = 0, note = "", context = "" } }
    require("codetour.config").merge { signs = { text = "●" } }
    anchor.attach(bufnr, stops)
    signs.refresh(bufnr, stops)

    local NS = vim.api.nvim_create_namespace "codetour_signs"
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
    assert.is_truthy(marks[1][4].sign_text:match "●")
    require("codetour.config").merge { signs = { text = nil } }
  end)

  it("refresh() does nothing when signs.enabled is false", function()
    local bufnr, file = buffer_with_lines { "a" }
    local stops = { { file = file, lnum = 1, col = 0, note = "", context = "" } }
    require("codetour.config").merge { signs = { enabled = false } }
    anchor.attach(bufnr, stops)
    signs.refresh(bufnr, stops)
    assert.is_nil(signs._buf_signs[bufnr])
    require("codetour.config").merge { signs = { enabled = true } }
  end)

  it("detach_all() clears every tracked sign", function()
    local bufnr, file = buffer_with_lines { "a" }
    local stops = { { file = file, lnum = 1, col = 0, note = "", context = "" } }
    anchor.attach(bufnr, stops)
    signs.refresh(bufnr, stops)
    signs.detach_all()
    assert.is_nil(next(signs._buf_signs))
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
    package.loaded["codetour.signs"] = nil
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
    state.create "test" -- Phase 10B: tour must be open before state.add
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
    assert.equals("billing", state.data.active_tour.name)

    vim.ui.select = function(items, _, on_choice)
      -- pick the first entry (auth, since list_tours sorts alphabetically)
      on_choice(items[1])
    end

    require("codetour.picker").tours()
    assert.equals("auth", state.data.active_tour.name, "picker should switch to chosen tour")
  end)
end)

describe("codetour.qf", function()
  local original_cwd
  local repo
  local qf

  before_each(function()
    original_cwd = vim.fn.getcwd()
    repo = tmpdir()
    init_git_repo(repo)
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    -- Force-reload qf and its transitive deps so qf_backup (module-local)
    -- starts as nil and each test exercises its own snapshot/restore lifecycle.
    package.loaded["codetour.qf"] = nil
    package.loaded["codetour.state"] = nil
    package.loaded["codetour.anchor"] = nil
    package.loaded["codetour.notes"] = nil
    package.loaded["codetour.signs"] = nil
    qf = require "codetour.qf"
    -- Reset qf list so leftover items from previous describe blocks don't
    -- confuse "expected empty qf" assertions.
    pcall(vim.fn.setqflist, {}, "r", { items = {}, title = "" })
  end)
  after_each(function()
    -- Reset the qf list so cross-test contamination doesn't leak
    pcall(vim.fn.setqflist, {}, "r", { items = {}, title = "" })
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end)

  local function add_stop(state, tmp, lnum, note)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    state.add(note)
  end

  it("open() warns and bails when there are no stops", function()
    local state = require "codetour.state"
    state.create "empty"
    local captured
    local original_notify = vim.notify
    vim.notify = function(msg, _)
      captured = msg
    end
    qf.open()
    vim.notify = original_notify
    assert.is_truthy(captured and captured:match "no stops to open")
    assert.equals(0, #vim.fn.getqflist())
  end)

  it("open() populates qf with one item per stop, correct filename/lnum/col/text", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c", "d" }, tmp)
    local state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add
    add_stop(state, tmp, 1, "first")
    add_stop(state, tmp, 3, "third")

    qf.open()

    local items = vim.fn.getqflist()
    assert.equals(2, #items)
    assert.equals(1, items[1].lnum)
    assert.equals("first", items[1].text)
    assert.equals(3, items[2].lnum)
    assert.equals("third", items[2].text)
  end)

  it("open() sets title 'tour:<branch>'", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a" }, tmp)
    local state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add
    add_stop(state, tmp, 1, "x")

    qf.open()
    local title = (vim.fn.getqflist { title = 1 } or {}).title or ""
    assert.is_truthy(title:match "^tour:")
    assert.is_truthy(title:match "main", "branch should appear in title: " .. title)
  end)

  it("open() snapshots a prior non-tour qf list; close() restores it", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a" }, tmp)
    local state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add
    add_stop(state, tmp, 1, "stop")

    -- Stage a "prior" :grep-like qf list
    vim.fn.setqflist({}, " ", {
      title = "[grep] foo",
      items = { { filename = tmp, lnum = 1, col = 1, text = "grep hit" } },
    })

    qf.open() -- snapshots the grep list, replaces with tour items
    local mid_title = (vim.fn.getqflist { title = 1 } or {}).title or ""
    assert.is_truthy(mid_title:match "^tour:", "qf should now be the tour list")

    qf.close()
    local restored = vim.fn.getqflist { title = 1, items = 1 } or {}
    assert.equals("[grep] foo", restored.title)
    assert.equals(1, #restored.items)
    assert.equals("grep hit", restored.items[1].text)
  end)

  it("close() with no prior backup clears the qf list", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a" }, tmp)
    local state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add
    add_stop(state, tmp, 1, "stop")

    -- No prior qf — close before open should still no-crash and leave qf empty
    qf.close()
    assert.equals(0, #vim.fn.getqflist())
    assert.equals("", (vim.fn.getqflist { title = 1 } or {}).title or "")
  end)

  it("open() is idempotent: a second call while in a tour does not re-snapshot", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a" }, tmp)
    local state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add
    add_stop(state, tmp, 1, "stop")

    vim.fn.setqflist({}, " ", {
      title = "[grep] real-prior",
      items = { { filename = tmp, lnum = 1, col = 1, text = "real-prior hit" } },
    })

    qf.open() -- snapshots "real-prior"
    qf.open() -- if this re-snapshots, the backup becomes the tour list and close() can't restore

    qf.close()
    local restored = vim.fn.getqflist { title = 1, items = 1 } or {}
    assert.equals("[grep] real-prior", restored.title, "second open() must not have clobbered the backup")
    assert.equals("real-prior hit", restored.items[1].text)
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
    package.loaded["codetour.signs"] = nil
    state = require "codetour.state"
  end)
  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end)

  it("create() makes a new tour active and persists an empty file", function()
    state.create "auth"
    assert.equals("auth", state.data.active_tour.name)
    assert.equals(0, #state.data.active_tour.stops)
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

  it("open() switches the active tour and reloads its stops", function()
    state.create "auth"
    -- pretend we added a stop manually
    state.data.active_tour.stops = { { file = "/x", lnum = 1, col = 0, note = "auth-stop", context = "" } }
    storage.save_tour(state.data.active_tour)

    state.create "billing"
    assert.equals("billing", state.data.active_tour.name)
    assert.equals(0, #state.data.active_tour.stops)

    state.open "auth"
    assert.equals("auth", state.data.active_tour.name)
    assert.equals("auth-stop", state.data.active_tour.stops[1].note)
  end)

  it("open() warns and no-ops when the tour doesn't exist", function()
    state.create "auth"
    state.open "nope"
    assert.equals("auth", state.data.active_tour.name, "active tour should be unchanged")
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
    assert.equals("billing", state.data.active_tour.name)
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

  it("rename() refuses with no active tour", function()
    state.rename "new-name"
    assert.is_nil(state.data.active_tour, "no tour should be created by rename")
    assert.equals(0, #storage.list_tours())
  end)

  it("rename() refuses invalid characters in the new name", function()
    state.create "auth"
    state.rename "auth/v2"
    assert.equals("auth", state.data.active_tour.name, "active tour name unchanged on invalid input")
    assert.same({ "auth" }, storage.list_tours())
  end)

  it("rename() refuses when the new name already exists", function()
    state.create "auth"
    state.create "billing" -- billing is now active
    state.rename "auth" -- billing → auth: would collide
    assert.equals("billing", state.data.active_tour.name)
    assert.same({ "auth", "billing" }, storage.list_tours(), "no files moved or removed")
  end)

  it("rename() is a no-op when the name didn't change", function()
    state.create "auth"
    state.rename "auth"
    assert.equals("auth", state.data.active_tour.name)
    assert.same({ "auth" }, storage.list_tours())
  end)

  it("rename() updates in-memory name, active pointer, and filesystem", function()
    state.create "auth"
    state.rename "user-auth"

    assert.equals("user-auth", state.data.active_tour.name, "in-memory name updated")
    assert.equals("user-auth", storage.read_active(), "active-tour pointer updated")
    assert.same({ "user-auth" }, storage.list_tours(), "old file gone, new file present")

    local info = git.info()
    assert.equals(0, vim.fn.filereadable(info.root .. "/.codetour/auth.json"), "old file deleted")
    assert.equals(1, vim.fn.filereadable(info.root .. "/.codetour/user-auth.json"), "new file written")
  end)

  it("ensure_loaded() restores the last-active tour on a fresh load", function()
    state.create "billing"
    -- New module instance, simulating nvim restart
    package.loaded["codetour.state"] = nil
    local fresh = require "codetour.state"
    fresh.ensure_loaded()
    assert.equals("billing", fresh.data.active_tour.name)
  end)

  it("ensure_loaded() clears the active pointer when the file is missing", function()
    storage.write_active "ghost" -- pointer to nonexistent tour
    package.loaded["codetour.state"] = nil
    local fresh = require "codetour.state"
    fresh.ensure_loaded()
    assert.is_nil(fresh.data.active_tour, "phantom pointer should be cleared")
    assert.is_nil(storage.read_active())
  end)

  it("ensure_loaded() detects offline drift for stops whose files aren't loaded", function()
    -- Set up: write a file with a known context line and persist a tour
    -- pointing at it. Then modify the file on disk to shift the content.
    -- On a fresh ensure_loaded() (file not loaded as a buffer), the stop's
    -- lnum should reflect the post-drift position — not the persisted one.
    -- This is the bug reported in the manual smoke test: qf was pointing
    -- to the pre-drift line while virt_lines (set on later BufRead) were
    -- at the post-drift line.
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({
      "line 1",
      "line 2",
      "line 3",
      "function dispatch(args)",
      "line 5",
    }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    state.create "drift-test" -- Phase 10B: tour must be open before state.add
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    state.add "dispatch"
    assert.equals(4, state.data.active_tour.stops[1].lnum)

    -- Wipe the buffer so the file is no longer loaded — this is critical;
    -- otherwise BufRead would handle drift via the extmark path on reload.
    vim.cmd("bwipeout! " .. vim.fn.fnameescape(tmp))

    -- Now drift the file on disk (prepend 2 lines).
    vim.fn.writefile({
      "NEW preamble 1",
      "NEW preamble 2",
      "line 1",
      "line 2",
      "line 3",
      "function dispatch(args)",
      "line 5",
    }, tmp)

    -- Force a cold reload of state. ensure_loaded should run offline drift
    -- detection and update stop.lnum to 6 (its new position).
    package.loaded["codetour.state"] = nil
    package.loaded["codetour.anchor"] = nil
    local fresh = require "codetour.state"
    fresh.ensure_loaded()

    assert.equals(6, fresh.data.active_tour.stops[1].lnum, "offline drift should re-anchor before any buffer load")
  end)

  it("add() refuses with a clear error when no tour is open", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "line 1" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local captured
    local original_notify = vim.notify
    vim.notify = function(msg, _)
      captured = msg
    end

    state.add "first"

    vim.notify = original_notify
    assert.is_nil(state.data.active_tour, "no tour should be auto-created any more")
    assert.is_truthy(captured and captured:match "no tour open", "error must mention 'no tour open'")
    assert.is_truthy(
      captured:match ":CodeTour open" or captured:match ":CodeTour create",
      "error must point at the recovery commands"
    )
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
    -- Empty-text check happens before the active-tour check, so we don't
    -- strictly need a tour — but set one up so the asserts have something
    -- meaningful to read back from.
    state.data.active_tour = Tour.new "default"
    state.data.active_tour.stops = { { file = "/anything", lnum = 1, col = 0, note = "old", context = "" } }
    state.edit_note ""
    assert.equals("old", state.data.active_tour.stops[1].note)
    state.edit_note(nil)
    assert.equals("old", state.data.active_tour.stops[1].note)
  end)

  it("edit_note() updates the nearest stop's note in the current buffer", function()
    -- Open a real file so the buffer's path matches the stop's file
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "line 1", "line 2", "line 3" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    -- Tour stops carry canonical paths post-Phase-2 (state.add canonicalises
    -- on insert). When bypassing state.add to inject stops manually, we have
    -- to canonicalise ourselves so Tour.nearest_stop_idx's string-equality
    -- lookup against the buffer's canonical path matches.
    local util = require "codetour.util"
    local canonical = util.canonical(tmp)
    state.data.active_tour = Tour.new "default"
    state.data.active_tour.stops = {
      { file = canonical, lnum = 1, col = 0, note = "first", context = "" },
      { file = canonical, lnum = 2, col = 0, note = "second", context = "" },
      { file = canonical, lnum = 3, col = 0, note = "third", context = "" },
    }
    state.data.loaded = true

    state.edit_note "rewritten"
    assert.equals("rewritten", state.data.active_tour.stops[2].note) -- nearest to cursor on line 2
    assert.equals("first", state.data.active_tour.stops[1].note) -- unchanged
    assert.equals("third", state.data.active_tour.stops[3].note) -- unchanged
  end)

  it("edit_note() bails when no stop is in the current buffer", function()
    vim.cmd "enew"
    state.data.active_tour = Tour.new "default"
    state.data.active_tour.stops = { { file = "/elsewhere/file.lua", lnum = 1, col = 0, note = "old", context = "" } }
    state.data.loaded = true
    state.edit_note "rewritten"
    assert.equals("old", state.data.active_tour.stops[1].note)
  end)

  it("edit_note() refreshes the quickfix list when a tour is active", function()
    -- Build a real file and a real stop, prime an active tour qf
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "line 1", "line 2" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local util = require "codetour.util"
    state.data.active_tour = Tour.new "default"
    state.data.active_tour.stops = { { file = util.canonical(tmp), lnum = 1, col = 0, note = "before", context = "" } }
    state.data.loaded = true

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
    state.create "test" -- Phase 10B: tour must be open before state.add
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
    state.create "test" -- Phase 10B: tour must be open before state.add
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
    state.create "test" -- Phase 10B: tour must be open before state.add

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
    state.create "test" -- Phase 10B: tour must be open before state.add
    state.add "first"
    assert.equals(1, #state.data.active_tour.stops)
    -- Same line, different note text → should still refuse
    state.add "second attempt"
    assert.equals(1, #state.data.active_tour.stops, "duplicate at same lnum should be refused")
    assert.equals("first", state.data.active_tour.stops[1].note)
  end)

  it("add() allows same lnum across different files", function()
    local tmp1 = vim.fn.tempname() .. ".lua"
    local tmp2 = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "line 1", "line 2" }, tmp1)
    vim.fn.writefile({ "line 1", "line 2" }, tmp2)

    package.loaded["codetour.state"] = nil
    state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add

    vim.cmd("e " .. vim.fn.fnameescape(tmp1))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "in tmp1"

    vim.cmd("e " .. vim.fn.fnameescape(tmp2))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "in tmp2"

    assert.equals(2, #state.data.active_tour.stops, "same lnum in different files should both be added")
  end)

  it("remove() drops the nearest stop and shifts remaining indices", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c", "d", "e" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))

    package.loaded["codetour.state"] = nil
    state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "first"
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    state.add "third"
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    state.add "fifth"
    assert.equals(3, #state.data.active_tour.stops)

    -- Cursor near the middle stop
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    state.remove()
    assert.equals(2, #state.data.active_tour.stops)
    assert.equals("first", state.data.active_tour.stops[1].note)
    assert.equals("fifth", state.data.active_tour.stops[2].note) -- index shifted down
  end)

  it("remove() bails when no stop is in the current buffer", function()
    package.loaded["codetour.state"] = nil
    state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add
    vim.cmd "enew"
    state.data.active_tour = Tour.new "default"
    state.data.active_tour.stops = { { file = "/elsewhere/file.lua", lnum = 1, col = 0, note = "x", context = "" } }
    state.data.loaded = true
    state.remove()
    assert.equals(1, #state.data.active_tour.stops, "no removal should occur")
  end)

  it("add() preserves the current quickfix index when syncing", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c", "d" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))

    package.loaded["codetour.state"] = nil
    state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add

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
    state.create "test" -- Phase 10B: tour must be open before state.add

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
    state.create "test" -- Phase 10B: tour must be open before state.add

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
    state.create "first-tour" -- Phase 10B: tour must be open before state.add

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "first"

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
    state.create "test" -- Phase 10B: tour must be open before state.add

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

  it("next_stop_in_buf() moves cursor down to next stop by lnum", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c", "d", "e", "f" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))

    package.loaded["codetour.state"] = nil
    state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add

    -- Three stops at lines 5, 2, 4 — added in non-sorted order to verify
    -- next_stop_in_buf sorts by lnum, not by stop index.
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    state.add "third by line"
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    state.add "first by line"
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    state.add "second by line"

    -- Sit on line 1; next should land on line 2 (the lowest-line stop)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.next_stop_in_buf()
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])

    -- Next from 2 → 4 (skipping over the cursor's current stop)
    state.next_stop_in_buf()
    assert.equals(4, vim.api.nvim_win_get_cursor(0)[1])

    -- Next from 4 → 5
    state.next_stop_in_buf()
    assert.equals(5, vim.api.nvim_win_get_cursor(0)[1])

    -- Next from 5 → no further stop, cursor stays
    state.next_stop_in_buf()
    assert.equals(5, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("prev_stop_in_buf() moves cursor up to previous stop by lnum", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c", "d", "e", "f" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))

    package.loaded["codetour.state"] = nil
    state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    state.add "first by line"
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    state.add "third by line"
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    state.add "second by line"

    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    state.prev_stop_in_buf()
    assert.equals(5, vim.api.nvim_win_get_cursor(0)[1])

    state.prev_stop_in_buf()
    assert.equals(4, vim.api.nvim_win_get_cursor(0)[1])

    state.prev_stop_in_buf()
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])

    -- No earlier stop; cursor stays
    state.prev_stop_in_buf()
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("next_stop_in_buf() reports an error when there is no next stop", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))

    package.loaded["codetour.state"] = nil
    state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "only stop"

    local captured
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      captured = { msg = msg, level = level }
    end

    -- Cursor is past the only stop → no next
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    state.next_stop_in_buf()

    vim.notify = original_notify

    assert.is_not_nil(captured, "expected an error notify")
    assert.is_truthy(captured.msg:match "no next stop", "got: " .. tostring(captured.msg))
    assert.equals(vim.log.levels.ERROR, captured.level)
  end)

  it("prev_stop_in_buf() reports an error when there is no previous stop", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))

    package.loaded["codetour.state"] = nil
    state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    state.add "only stop"

    local captured
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      captured = { msg = msg, level = level }
    end

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.prev_stop_in_buf()

    vim.notify = original_notify

    assert.is_not_nil(captured)
    assert.is_truthy(captured.msg:match "no previous stop")
    assert.equals(vim.log.levels.ERROR, captured.level)
  end)

  it("next/prev_stop_in_buf() ignore stops in other files", function()
    local fileA = vim.fn.tempname() .. "_a.lua"
    local fileB = vim.fn.tempname() .. "_b.lua"
    vim.fn.writefile({ "a1", "a2", "a3" }, fileA)
    vim.fn.writefile({ "b1", "b2", "b3" }, fileB)

    package.loaded["codetour.state"] = nil
    state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add

    vim.cmd("e " .. vim.fn.fnameescape(fileA))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "in A"

    vim.cmd("e " .. vim.fn.fnameescape(fileB))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "in B"

    -- Now in fileB, line 1. next/prev should be no-ops since there's only
    -- one stop in this file (and we're sitting on it).
    state.next_stop_in_buf()
    assert.equals(1, vim.api.nvim_win_get_cursor(0)[1])
    state.prev_stop_in_buf()
    assert.equals(1, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("next_stop_in_buf() does not modify state, qf, or trigger save", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))

    package.loaded["codetour.state"] = nil
    state = require "codetour.state"
    state.create "test" -- Phase 10B: tour must be open before state.add
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.add "one"
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    state.add "two"

    -- Set up an active tour qf with a known idx
    vim.fn.setqflist({}, " ", {
      title = "tour:test",
      items = { { filename = tmp, lnum = 1 }, { filename = tmp, lnum = 3 } },
    })
    vim.fn.setqflist({}, "r", { nr = 0, idx = 2 })
    local before_idx = vim.fn.getqflist({ idx = 0 }).idx
    local before_stops = vim.deepcopy(state.data.active_tour.stops)

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    state.next_stop_in_buf() -- moves cursor to line 3

    -- qf idx untouched
    assert.equals(before_idx, vim.fn.getqflist({ idx = 0 }).idx)
    -- stops list untouched
    assert.same(before_stops, state.data.active_tour.stops)
  end)

  it("edit_note() leaves a non-tour quickfix list alone", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "line 1" }, tmp)
    vim.cmd("e " .. vim.fn.fnameescape(tmp))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local util = require "codetour.util"
    state.data.active_tour = Tour.new "default"
    state.data.active_tour.stops = { { file = util.canonical(tmp), lnum = 1, col = 0, note = "old", context = "" } }
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
