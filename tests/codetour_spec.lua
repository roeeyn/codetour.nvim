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

  it("returns nil when no file exists yet", function()
    assert.is_nil(storage.load())
  end)

  it("round-trips an empty path", function()
    storage.save("default", {})
    local loaded = storage.load()
    assert.is_not_nil(loaded)
    assert.equals("default", loaded.path_name)
    assert.equals(0, #loaded.stops)
  end)

  it("converts absolute paths to relative on save and back on load", function()
    local info = git.info()
    local stops = {
      { file = info.root .. "/foo.lua", lnum = 10, col = 0, note = "entry" },
      { file = info.root .. "/bar/baz.py", lnum = 42, col = 4, note = "" },
    }
    storage.save("default", stops)

    -- Verify on-disk file uses relative paths
    local f = io.open(info.file, "r")
    local raw = f:read "*a"
    f:close()
    local decoded = vim.fn.json_decode(raw)
    assert.equals("foo.lua", decoded.paths[1].stops[1].file)
    assert.equals("bar/baz.py", decoded.paths[1].stops[2].file)

    -- Verify load reconstructs absolute paths
    local loaded = storage.load()
    assert.equals(info.root .. "/foo.lua", loaded.stops[1].file)
    assert.equals(10, loaded.stops[1].lnum)
    assert.equals("entry", loaded.stops[1].note)
  end)

  it("returns nil on malformed JSON", function()
    local info = git.info()
    vim.fn.mkdir(vim.fn.fnamemodify(info.file, ":h"), "p")
    local f = io.open(info.file, "w")
    f:write "garbage{{{"
    f:close()
    assert.is_nil(storage.load())
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

describe("codetour.state", function()
  local state
  local original_cwd
  local repo

  before_each(function()
    original_cwd = vim.fn.getcwd()
    repo = tmpdir()
    init_git_repo(repo)
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    -- Re-require so state.data starts fresh per test
    package.loaded["codetour.state"] = nil
    state = require "codetour.state"
  end)
  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end)

  it("start() defaults to 'default' when no name given", function()
    state.start(nil)
    assert.equals("default", state.data.path_name)
    assert.equals(0, #state.data.stops)
  end)

  it("start() resets stops and sets path_name", function()
    state.data.stops = { { file = "x", lnum = 1, col = 0, note = "" } }
    state.data.path_name = "old"
    state.start "auth"
    assert.equals("auth", state.data.path_name)
    assert.equals(0, #state.data.stops)
  end)

  it("start() persists; ensure_loaded() picks up the persisted name", function()
    state.start "billing"
    package.loaded["codetour.state"] = nil
    local fresh = require "codetour.state"
    fresh.ensure_loaded()
    assert.equals("billing", fresh.data.path_name)
  end)
end)
