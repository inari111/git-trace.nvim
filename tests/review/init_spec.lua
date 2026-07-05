local review = require("git-trace.review")
local git = require("git-trace.git")
local github = require("git-trace.provider.github")
local review_git = require("git-trace.review.git")
local worktree = require("git-trace.review.worktree")
local config = require("git-trace.config")

describe("review.open", function()
  local orig = {}
  local notifications
  local qf_calls

  before_each(function()
    orig.repo_root = git.repo_root
    orig.remote_url = git.remote_url
    orig.pr_view = github.pr_view
    orig.list_open_prs = github.list_open_prs
    orig.ensure = worktree.ensure
    orig.merge_base = review_git.merge_base
    orig.changed_files = review_git.changed_files
    orig.notify = vim.notify
    orig.setqflist = vim.fn.setqflist
    orig.buf_get_name = vim.api.nvim_buf_get_name
    orig.getcwd = vim.fn.getcwd
    orig.open_qf = config.values.review.open_qf

    notifications = {}
    qf_calls = {}

    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end
    vim.fn.setqflist = function(...)
      table.insert(qf_calls, { ... })
      return 0
    end
    vim.api.nvim_buf_get_name = function()
      return ""
    end
    vim.fn.getcwd = function()
      return "/repo"
    end
    config.values.review.open_qf = false

    git.repo_root = function(_, cb)
      cb("/repo", nil)
    end
    git.remote_url = function(_, cb)
      cb("git@github.com:inari111/git-trace.nvim.git", nil)
    end
    github.pr_view = function(_, _, cb)
      cb({ number = 42, title = "Fix bug", state = "OPEN", base_ref = "main", url = "u", head_oid = "h" }, nil)
    end
    worktree.ensure = function(_, _, _, _, cb)
      cb("/wt", nil)
    end
    review_git.merge_base = function(_, _, _, cb)
      cb("basesha", nil)
    end
    review_git.changed_files = function(_, _, _, cb)
      cb({ { path = "a.lua", status = "M", additions = 1, deletions = 1, binary = false } }, nil)
    end
  end)

  after_each(function()
    git.repo_root = orig.repo_root
    git.remote_url = orig.remote_url
    github.pr_view = orig.pr_view
    github.list_open_prs = orig.list_open_prs
    worktree.ensure = orig.ensure
    review_git.merge_base = orig.merge_base
    review_git.changed_files = orig.changed_files
    vim.api.nvim_buf_get_name = orig.buf_get_name
    vim.fn.getcwd = orig.getcwd
    config.values.review.open_qf = orig.open_qf

    review.close()
    review._opening = false
    vim.notify = orig.notify
    vim.fn.setqflist = orig.setqflist
  end)

  local function has_level(level)
    for _, n in ipairs(notifications) do
      if n.level == level then
        return true
      end
    end
    return false
  end

  it("builds a session and sets the quickfix list on success", function()
    review.open(42)

    local session = review._get_session()
    assert.is_not_nil(session)
    assert.equals("/wt", session.worktree)
    assert.equals("basesha", session.merge_base)
    assert.equals(42, session.pr.number)
    assert.is_true(session.diff_enabled)
    assert.equals("number", type(session.augroup))
    assert.equals(1, #session.files)
    assert.is_not_nil(session.files_by_path["/wt/a.lua"])

    assert.equals(1, #qf_calls)
    local opts = qf_calls[1][3]
    assert.equals("GitTrace PR #42: Fix bug", opts.title)
    assert.equals(42, opts.context.git_trace_review)
    assert.equals(1, #opts.items)
    assert.is_false(review._opening)
  end)

  it("aborts when pr_view fails", function()
    github.pr_view = function(_, _, cb)
      cb(nil, "pr view failed")
    end

    review.open(42)

    assert.is_nil(review._get_session())
    assert.equals(0, #qf_calls)
    assert.is_true(has_level(vim.log.levels.ERROR))
    assert.is_false(review._opening)
  end)

  it("aborts when the PR has no changed files", function()
    review_git.changed_files = function(_, _, _, cb)
      cb({}, nil)
    end

    review.open(42)

    assert.is_nil(review._get_session())
    assert.equals(0, #qf_calls)
    assert.is_true(has_level(vim.log.levels.INFO))
    assert.is_false(review._opening)
  end)

  it("is a no-op to close with no active session", function()
    assert.has_no.errors(function()
      review.close()
      review.close()
    end)
    assert.is_nil(review._get_session())
  end)

  it("closes an active session and clears it", function()
    review.open(42)
    assert.is_not_nil(review._get_session())
    review.close()
    assert.is_nil(review._get_session())
  end)

  it("guards against re-entrant opens", function()
    local root_calls = 0
    git.repo_root = function()
      root_calls = root_calls + 1
    end

    review.open(42)
    review.open(42)

    assert.equals(1, root_calls)
    assert.is_true(has_level(vim.log.levels.WARN))
  end)
end)

describe("review.next_hunk / review.prev_hunk", function()
  local WT = "/gittrace-hunkjump-test-wt"
  local orig = {}
  local notifications
  local win

  ---@param files GitTraceReviewFile[]
  ---@param diff_enabled boolean|nil
  local function make_session(files, diff_enabled)
    local files_by_path = {}
    for _, f in ipairs(files) do
      files_by_path[WT .. "/" .. f.path] = f
    end
    return {
      pr = { number = 3 },
      repo_root = "/repo",
      worktree = WT,
      merge_base = "cafef00d1234567890",
      files = files,
      files_by_path = files_by_path,
      diff_enabled = diff_enabled or false,
    }
  end

  local function open_file(relpath, lines)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, WT .. "/" .. relpath)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    return win, buf
  end

  before_each(function()
    orig.diff_hunks = review_git.diff_hunks
    orig.notify = vim.notify
    notifications = {}
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end
  end)

  after_each(function()
    review_git.diff_hunks = orig.diff_hunks
    vim.notify = orig.notify
    review.close()
    pcall(vim.cmd, "silent! only")
    pcall(vim.cmd, "silent! diffoff!")
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  it("warns when there is no active session", function()
    review.next_hunk()

    assert.equals(1, #notifications)
    assert.equals(vim.log.levels.WARN, notifications[1].level)
    assert.matches("No active review session", notifications[1].msg)
  end)

  it("warns when the current buffer is not part of the review", function()
    review._session = make_session({ { path = "a.lua", status = "M", binary = false } })
    open_file("unrelated.lua", { "l1" })

    review.prev_hunk()

    assert.equals(1, #notifications)
    assert.matches("not part of the active review", notifications[1].msg)
  end)

  it("warns and defers to native diff jumps when the session is in diff view", function()
    review._session = make_session({ { path = "a.lua", status = "M", binary = false } }, true)
    open_file("a.lua", { "l1", "l2", "l3" })

    review.next_hunk()

    assert.equals(1, #notifications)
    assert.matches("diff view", notifications[1].msg)
  end)

  it("moves the cursor to the next hunk in single-file view", function()
    review._session = make_session({ { path = "a.lua", status = "M", binary = false } })
    review_git.diff_hunks = function(_, _, _, _, cb)
      cb({ { old_start = 2, old_count = 1, new_start = 2, new_count = 1 } }, nil)
    end
    open_file("a.lua", { "l1", "l2", "l3" })
    vim.api.nvim_win_set_cursor(win, { 1, 0 })

    review.next_hunk()

    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(win))
  end)

  it("moves the cursor to the previous hunk in single-file view", function()
    review._session = make_session({ { path = "a.lua", status = "M", binary = false } })
    review_git.diff_hunks = function(_, _, _, _, cb)
      cb({ { old_start = 2, old_count = 1, new_start = 2, new_count = 1 } }, nil)
    end
    open_file("a.lua", { "l1", "l2", "l3" })
    vim.api.nvim_win_set_cursor(win, { 3, 0 })

    review.prev_hunk()

    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(win))
  end)

  it("caches hunks across repeated jumps (single fetch)", function()
    review._session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local fetch_count = 0
    review_git.diff_hunks = function(_, _, _, _, cb)
      fetch_count = fetch_count + 1
      cb({ { old_start = 2, old_count = 1, new_start = 2, new_count = 1 } }, nil)
    end
    open_file("a.lua", { "l1", "l2", "l3" })
    vim.api.nvim_win_set_cursor(win, { 1, 0 })

    review.next_hunk()
    review.next_hunk()

    assert.equals(1, fetch_count)
  end)
end)
