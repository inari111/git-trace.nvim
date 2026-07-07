local ui_diff = require("git-trace.review.ui.diff")
local review_git = require("git-trace.review.git")
local config = require("git-trace.config")

describe("review.ui.diff", function()
  local WT = "/gittrace-test-wt"
  local orig = {}
  local notifications

  ---Build a fake review session for the given file list.
  local function make_session(files)
    local files_by_path = {}
    for _, f in ipairs(files) do
      files_by_path[WT .. "/" .. f.path] = f
    end
    return {
      pr = { number = 7 },
      repo_root = "/repo",
      worktree = WT,
      merge_base = "abcdef1234567890",
      files = files,
      files_by_path = files_by_path,
      diff_enabled = true,
    }
  end

  ---Open a review file (named at its worktree path) in the current window.
  local function open_file(relpath, lines)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, WT .. "/" .. relpath)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "head1", "head2" })
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.w[win].git_trace_attached = nil
    return win, buf
  end

  local function win_count()
    return #vim.api.nvim_tabpage_list_wins(0)
  end

  ---True if any window in the current tabpage holds a quickfix buffer.
  local function qf_window_open()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "quickfix" then
        return true
      end
    end
    return false
  end

  ---Populate and open the quickfix list, optionally stamping it as git-trace's own.
  ---@param context table|nil qf context; pass a git_trace_review marker or nil/other for "not mine"
  local function open_qf(context)
    vim.fn.setqflist({}, " ", {
      items = { { filename = WT .. "/a.lua", lnum = 1, text = "M +0 -0  a.lua" } },
      context = context,
    })
    vim.cmd.copen()
  end

  ---Show a scratch buffer (buftype=nofile) with the given filetype in the
  ---current window, mimicking a dashboard window.
  local function show_special_buf(ft)
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = ft
    vim.api.nvim_win_set_buf(win, buf)
    return win, buf
  end

  local function notified_matching(pattern)
    for _, n in ipairs(notifications) do
      if type(n.msg) == "string" and n.msg:match(pattern) then
        return n
      end
    end
    return nil
  end

  ---Buffer-local normal-mode keymaps set by git-trace (matched by their desc).
  local function git_trace_maps(buf)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if type(m.desc) == "string" and m.desc:match("^git%-trace:") then
        table.insert(out, m)
      end
    end
    return out
  end

  local function has_map(buf, lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == lhs then
        return true
      end
    end
    return false
  end

  before_each(function()
    orig.show_file = review_git.show_file
    orig.diff_hunks = review_git.diff_hunks
    orig.notify = vim.notify
    orig.keymaps = config.values.review.keymaps
    orig.close_qf_on_open = config.values.review.close_qf_on_open
    notifications = {}
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end
    -- Single-file view (Task 4) fetches hunks to draw signs; default to none so
    -- tests that don't care about signs don't need to stub this themselves.
    review_git.diff_hunks = function(_, _, _, _, cb)
      cb({}, nil)
    end
  end)

  after_each(function()
    review_git.show_file = orig.show_file
    review_git.diff_hunks = orig.diff_hunks
    vim.notify = orig.notify
    config.values.review.keymaps = orig.keymaps
    config.values.review.close_qf_on_open = orig.close_qf_on_open
    pcall(vim.cmd, "silent! cclose")
    pcall(vim.cmd, "silent! only")
    pcall(vim.cmd, "silent! diffoff!")
    pcall(vim.cmd, "silent! %bwipeout!")
    vim.fn.setqflist({}, "r", { items = {}, context = {}, title = "" })
  end)

  it("builds a native diff with a read-only base scratch buffer", function()
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "base1", "base2" }, nil)
    end
    local win = open_file("a.lua", { "head1", "head2" })

    ui_diff.attach(session, file, win)

    assert.equals(2, win_count())
    assert.is_not_nil(session.base_buf)
    assert.is_true(vim.api.nvim_buf_is_valid(session.base_buf))
    assert.equals("nofile", vim.bo[session.base_buf].buftype)
    assert.equals("wipe", vim.bo[session.base_buf].bufhidden)
    assert.is_false(vim.bo[session.base_buf].swapfile)
    assert.is_false(vim.bo[session.base_buf].modifiable)
    assert.equals("lua", vim.bo[session.base_buf].filetype)

    assert.is_true(vim.wo[session.base_win].diff)
    assert.is_true(vim.wo[session.main_win].diff)
    assert.equals(win, vim.api.nvim_get_current_win())
    assert.equals(win, session.main_win)

    assert.same({ "base1", "base2" }, vim.api.nvim_buf_get_lines(session.base_buf, 0, -1, false))
  end)

  it("removes the diff and restores saved window options in single view", function()
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "base1" }, nil)
    end
    local win = open_file("a.lua", { "head1" })

    vim.wo[win].foldmethod = "marker"
    vim.wo[win].wrap = true

    ui_diff.attach(session, file, win)
    assert.equals("diff", vim.wo[win].foldmethod)
    assert.is_true(vim.wo[win].diff)

    ui_diff.show_single(session, file, win)

    assert.equals(1, win_count())
    assert.is_false(vim.wo[win].diff)
    assert.equals("marker", vim.wo[win].foldmethod)
    assert.is_true(vim.wo[win].wrap)
    assert.is_nil(session.base_win)
  end)

  it("toggles between diff and single view for the focused file", function()
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "base1" }, nil)
    end
    local win = open_file("a.lua", { "head1" })

    ui_diff.attach(session, file, win)
    assert.is_true(session.diff_enabled)
    assert.equals(2, win_count())

    ui_diff.toggle(session)
    assert.is_false(session.diff_enabled)
    assert.equals(1, win_count())
    assert.is_false(vim.wo[win].diff)

    ui_diff.toggle(session)
    assert.is_true(session.diff_enabled)
    assert.equals(2, win_count())
    assert.is_true(vim.wo[win].diff)
  end)

  it("redirects a toggle from the base scratch window to the main file", function()
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "base1" }, nil)
    end
    local win = open_file("a.lua", { "head1" })

    ui_diff.attach(session, file, win)
    assert.is_true(session.diff_enabled)
    assert.equals(2, win_count())

    -- Focus the base scratch window and toggle from there. The scratch buffer is
    -- not in files_by_path, so this used to flip diff_enabled without tearing the
    -- layout down (state desync). It must instead act on the main worktree file.
    vim.api.nvim_set_current_win(session.base_win)
    ui_diff.toggle(session)

    assert.is_false(session.diff_enabled)
    assert.equals(1, win_count())
    assert.is_false(vim.wo[win].diff)
  end)

  it("refuses to toggle from a buffer outside the review without changing state", function()
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    -- An unnamed scratch buffer that is not part of any review.
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), other)

    ui_diff.toggle(session)

    assert.is_true(session.diff_enabled) -- unchanged
    assert.equals(1, win_count())
    assert.is_not_nil(notified_matching("not part of the active review"))
  end)

  it("warns and keeps the mode when toggling on a binary file", function()
    local session = make_session({ { path = "img.png", status = "M", binary = true } })
    local file = session.files[1]
    local win = open_file("img.png", { "data" })

    ui_diff.attach(session, file, win)
    ui_diff.toggle(session)

    assert.is_true(session.diff_enabled) -- unchanged
    assert.is_not_nil(notified_matching("not available"))
  end)

  it("warns and keeps the mode when toggling on a deleted file", function()
    local session = make_session({ { path = "gone.lua", status = "D", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "old1" }, nil)
    end
    local win = open_file("gone.lua", {})

    ui_diff.attach(session, file, win)
    assert.equals(1, win_count())

    ui_diff.toggle(session)

    assert.is_true(session.diff_enabled) -- unchanged
    assert.equals(1, win_count())
    assert.is_not_nil(notified_matching("not available"))
  end)

  it("re-attaches a deleted file when its quickfix entry is reopened", function()
    local session = make_session({ { path = "gone.lua", status = "D", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "old1", "old2" }, nil)
    end
    local win = open_file("gone.lua", {})

    ui_diff.attach(session, file, win)
    assert.same({ "old1", "old2" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false))

    -- Simulate quickfix re-selecting the same entry: a fresh empty placeholder
    -- lands in the window while the window-local marker is left untouched.
    local placeholder2 = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(placeholder2, WT .. "/gone.lua")
    vim.api.nvim_win_set_buf(win, placeholder2)

    ui_diff.attach(session, file, win)

    local shown = vim.api.nvim_win_get_buf(win)
    assert.is_true(shown ~= placeholder2)
    assert.same({ "old1", "old2" }, vim.api.nvim_buf_get_lines(shown, 0, -1, false))
    assert.is_false(vim.api.nvim_buf_is_valid(placeholder2))
  end)

  it("does not create a second base window when attach runs twice", function()
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "base1" }, nil)
    end
    local win = open_file("a.lua", { "head1" })

    ui_diff.attach(session, file, win)
    assert.equals(2, win_count())
    local first_base = session.base_win

    ui_diff.attach(session, file, win)
    assert.equals(2, win_count())
    assert.equals(first_base, session.base_win)
  end)

  it("uses an empty base for added files without calling git show", function()
    local session = make_session({ { path = "new.lua", status = "A", binary = false } })
    local file = session.files[1]
    local called = false
    review_git.show_file = function(_, _, _, cb)
      called = true
      cb({ "should not happen" }, nil)
    end
    local win = open_file("new.lua", { "n1", "n2" })

    ui_diff.attach(session, file, win)

    assert.is_false(called)
    assert.equals(2, win_count())
    assert.is_true(vim.wo[session.base_win].diff)
    assert.is_true(vim.wo[session.main_win].diff)
    assert.same({ "" }, vim.api.nvim_buf_get_lines(session.base_buf, 0, -1, false))
  end)

  it("swaps in the base buffer for a deleted file without diffing", function()
    local session = make_session({ { path = "gone.lua", status = "D", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "old1", "old2" }, nil)
    end
    local win, placeholder = open_file("gone.lua", {})

    ui_diff.attach(session, file, win)

    assert.equals(1, win_count())
    assert.is_false(vim.wo[win].diff)
    local shown = vim.api.nvim_win_get_buf(win)
    assert.is_true(shown ~= placeholder)
    assert.same({ "old1", "old2" }, vim.api.nvim_buf_get_lines(shown, 0, -1, false))
    assert.is_false(vim.api.nvim_buf_is_valid(placeholder))
    assert.is_not_nil(notified_matching("deleted in this PR"))
  end)

  it("does nothing when the window is gone before the base fetch resolves", function()
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    local pending
    review_git.show_file = function(_, _, _, cb)
      pending = cb
    end

    vim.cmd("vsplit")
    local win = open_file("a.lua", { "head1" })

    ui_diff.attach(session, file, win)
    assert.is_not_nil(pending)
    assert.equals(2, win_count())

    vim.api.nvim_win_close(win, true)
    assert.equals(1, win_count())

    assert.has_no.errors(function()
      pending({ "base1" }, nil)
    end)
    assert.equals(1, win_count())
    assert.is_nil(session.base_win)
  end)

  it("drops a stale base fetch after toggling back to single view", function()
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    local pending
    review_git.show_file = function(_, _, _, cb)
      pending = cb
    end
    local win = open_file("a.lua", { "head1" })

    -- attach starts show_diff (diff_enabled defaults true); hold the base fetch.
    ui_diff.attach(session, file, win)
    assert.is_not_nil(pending)
    assert.equals(1, win_count()) -- diff not built yet, waiting on the base

    -- User toggles to single view while the base fetch is still in flight.
    ui_diff.toggle(session)
    assert.is_false(session.diff_enabled)
    assert.equals(1, win_count())

    -- The late base fetch must not resurrect the diff layout.
    assert.has_no.errors(function()
      pending({ "base1" }, nil)
    end)
    assert.equals(1, win_count())
    assert.is_nil(session.base_win)
  end)

  it("teardown closes the base window and clears the attach marker", function()
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "b1" }, nil)
    end
    local win = open_file("a.lua", { "h1" })

    ui_diff.attach(session, file, win)
    assert.equals(2, win_count())
    assert.equals(WT .. "/a.lua", vim.w[win].git_trace_attached)

    ui_diff.teardown(session)

    assert.equals(1, win_count())
    assert.is_false(vim.wo[win].diff)
    assert.is_nil(session.base_win)
    assert.is_nil(vim.w[win].git_trace_attached)
  end)

  it("wires the review keymaps onto the worktree buffer and base scratch", function()
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "base1" }, nil)
    end
    local win, buf = open_file("a.lua", { "head1" })

    ui_diff.attach(session, file, win)

    assert.equals(6, #git_trace_maps(buf))
    assert.is_true(has_map(buf, "]f"))
    assert.is_true(has_map(buf, "[f"))
    assert.is_true(has_map(buf, "]c"))
    assert.is_true(has_map(buf, "[c"))

    assert.is_not_nil(session.base_buf)
    assert.equals(6, #git_trace_maps(session.base_buf))
  end)

  it("wires the review keymaps onto a deleted-file base buffer", function()
    local session = make_session({ { path = "gone.lua", status = "D", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "old1" }, nil)
    end
    local win = open_file("gone.lua", {})

    ui_diff.attach(session, file, win)

    local buf = vim.api.nvim_win_get_buf(win)
    assert.equals(6, #git_trace_maps(buf))
  end)

  it("wires no keymaps when review.keymaps is false", function()
    config.values.review.keymaps = false
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "base1" }, nil)
    end
    local win, buf = open_file("a.lua", { "head1" })

    ui_diff.attach(session, file, win)

    assert.equals(0, #git_trace_maps(buf))
    assert.equals(0, #git_trace_maps(session.base_buf))
  end)

  it("skips individually disabled keys", function()
    config.values.review.keymaps = {
      toggle_diff = "<leader>rd",
      next_file = "]f",
      prev_file = "[f",
      next_hunk = false,
      prev_hunk = "[c",
      close = "<leader>rq",
    }
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "base1" }, nil)
    end
    local win, buf = open_file("a.lua", { "head1" })

    ui_diff.attach(session, file, win)

    assert.equals(5, #git_trace_maps(buf))
    assert.is_false(has_map(buf, "]c"))
    assert.is_true(has_map(buf, "[c"))
    assert.is_true(has_map(buf, "]f"))
  end)

  it("closes the git-trace quickfix window before building the diff", function()
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "base1" }, nil)
    end
    local win = open_file("a.lua", { "head1" })

    open_qf({ git_trace_review = session.pr.number })
    assert.is_true(qf_window_open())

    ui_diff.attach(session, file, win)

    assert.is_false(qf_window_open())
    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.is_true(vim.wo[win].diff)
    assert.equals(win, session.main_win)
  end)

  it("keeps the quickfix window open when close_qf_on_open is false", function()
    config.values.review.close_qf_on_open = false
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "base1" }, nil)
    end
    local win = open_file("a.lua", { "head1" })

    open_qf({ git_trace_review = session.pr.number })
    assert.is_true(qf_window_open())

    ui_diff.attach(session, file, win)

    assert.is_true(qf_window_open())
    assert.is_true(vim.wo[win].diff)
  end)

  it("does not close a quickfix window that does not belong to git-trace", function()
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "base1" }, nil)
    end
    local win = open_file("a.lua", { "head1" })

    open_qf(nil)
    assert.is_true(qf_window_open())

    ui_diff.attach(session, file, win)

    assert.is_true(qf_window_open())
    assert.is_true(vim.wo[win].diff)
  end)

  for _, ft in ipairs({ "snacks_dashboard", "dashboard", "alpha", "ministarter", "starter", "startify" }) do
    it(("closes a %s window so the diff fills the screen"):format(ft), function()
      local session = make_session({ { path = "a.lua", status = "M", binary = false } })
      local file = session.files[1]
      review_git.show_file = function(_, _, _, cb)
        cb({ "base1" }, nil)
      end

      -- Dashboard occupies the initial window; quickfix cannot reuse a special
      -- window, so the file opens in a new split beside it (the bug scenario).
      local dash_win = show_special_buf(ft)
      vim.cmd("belowright split")
      local win = open_file("a.lua", { "head1" })
      assert.equals(2, win_count())

      ui_diff.attach(session, file, win)

      assert.is_false(vim.api.nvim_win_is_valid(dash_win))
      assert.equals(2, win_count()) -- exactly the two diff panes
      assert.is_true(vim.wo[win].diff)
      assert.equals(win, session.main_win)
    end)
  end

  it("keeps a normal second window open when a review file attaches", function()
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "base1" }, nil)
    end

    local other_win = vim.api.nvim_get_current_win()
    vim.cmd("belowright split")
    local win = open_file("a.lua", { "head1" })
    assert.equals(2, win_count())

    ui_diff.attach(session, file, win)

    assert.is_true(vim.api.nvim_win_is_valid(other_win))
    assert.equals(3, win_count()) -- normal window + base + main
  end)

  it("keeps a non-dashboard nofile window (e.g. a sidebar) open", function()
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "base1" }, nil)
    end

    local tree_win = show_special_buf("neo-tree")
    vim.cmd("belowright split")
    local win = open_file("a.lua", { "head1" })

    ui_diff.attach(session, file, win)

    assert.is_true(vim.api.nvim_win_is_valid(tree_win))
    assert.equals(3, win_count())
  end)

  it("keeps a regular file window whose filetype collides with a dashboard", function()
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "base1" }, nil)
    end

    -- A listed file buffer (buftype == "") that happens to have ft=dashboard
    -- must never be closed: buftype=nofile is required, not just the filetype.
    local other_win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = "dashboard"
    vim.api.nvim_win_set_buf(other_win, buf)
    vim.cmd("belowright split")
    local win = open_file("a.lua", { "head1" })

    ui_diff.attach(session, file, win)

    assert.is_true(vim.api.nvim_win_is_valid(other_win))
    assert.equals(3, win_count())
  end)

  it("closes both the dashboard and the git-trace quickfix window", function()
    local session = make_session({ { path = "a.lua", status = "M", binary = false } })
    local file = session.files[1]
    review_git.show_file = function(_, _, _, cb)
      cb({ "base1" }, nil)
    end

    local dash_win = show_special_buf("snacks_dashboard")
    vim.cmd("belowright split")
    local win = open_file("a.lua", { "head1" })
    open_qf({ git_trace_review = session.pr.number })
    assert.equals(3, win_count())

    ui_diff.attach(session, file, win)

    assert.is_false(vim.api.nvim_win_is_valid(dash_win))
    assert.is_false(qf_window_open())
    assert.equals(2, win_count())
    assert.is_true(vim.wo[win].diff)
  end)
end)
