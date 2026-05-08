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
