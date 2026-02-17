local git_trace = require("git-trace")

describe("git-trace setup", function()
  it("can be called twice without error", function()
    assert.has_no.errors(function()
      git_trace.setup({})
      git_trace.setup({})
    end)
  end)
end)

describe("browse_open", function()
  local git_mod = require("git-trace.git")
  local orig_buf_get_name
  local orig_schedule
  local orig_repo_root
  local orig_remote_url
  local orig_head_hash
  local orig_ui_open
  local captured_url

  before_each(function()
    orig_buf_get_name = vim.api.nvim_buf_get_name
    orig_schedule = vim.schedule
    orig_repo_root = git_mod.repo_root
    orig_remote_url = git_mod.remote_url
    orig_head_hash = git_mod.head_hash
    orig_ui_open = vim.ui.open
    captured_url = nil

    vim.api.nvim_buf_get_name = function() return "/repo/src/file.lua" end
    vim.schedule = function(fn) fn() end
    git_mod.repo_root = function(_, cb) cb("/repo", nil) end
    git_mod.remote_url = function(_, cb) cb("git@github.com:user/repo.git", nil) end
    git_mod.head_hash = function(_, cb) cb("abc123", nil) end
    vim.ui.open = function(url) captured_url = url end
  end)

  after_each(function()
    vim.api.nvim_buf_get_name = orig_buf_get_name
    vim.schedule = orig_schedule
    git_mod.repo_root = orig_repo_root
    git_mod.remote_url = orig_remote_url
    git_mod.head_hash = orig_head_hash
    vim.ui.open = orig_ui_open
  end)

  it("passes Visual range line1/line2 to build_file_url", function()
    git_trace.browse_open({ range = 2, line1 = 10, line2 = 20 })

    assert.is_not_nil(captured_url)
    assert.truthy(captured_url:match("#L10%-L20$"))
  end)
end)
