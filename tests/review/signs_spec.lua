local signs = require("git-trace.review.ui.signs")

describe("review.ui.signs highlight resilience", function()
  it("registers a ColorScheme autocmd under its own augroup", function()
    -- Errors (not just returns empty) when the augroup does not exist, so this
    -- fails before the autocmd is wired.
    local autocmds = vim.api.nvim_get_autocmds({ event = "ColorScheme", group = "GitTraceReviewSigns" })
    assert.is_true(#autocmds >= 1)
  end)

  it("(re)establishes the review highlight links when ColorScheme fires", function()
    vim.api.nvim_exec_autocmds("ColorScheme", {})

    assert.equals("DiffAdd", vim.api.nvim_get_hl(0, { name = "GitTraceReviewAdd", link = true }).link)
    assert.equals("DiffChange", vim.api.nvim_get_hl(0, { name = "GitTraceReviewChange", link = true }).link)
    assert.equals("DiffDelete", vim.api.nvim_get_hl(0, { name = "GitTraceReviewDelete", link = true }).link)
  end)
end)

describe("review.ui.signs", function()
  describe("marks_for", function()
    it("expands an add hunk across its new-side line range", function()
      local marks = signs.marks_for({ { old_start = 5, old_count = 0, new_start = 10, new_count = 3 } })
      assert.same({
        { line = 10, kind = "add" },
        { line = 11, kind = "add" },
        { line = 12, kind = "add" },
      }, marks)
    end)

    it("marks a change hunk across its new-side line range", function()
      local marks = signs.marks_for({ { old_start = 5, old_count = 2, new_start = 5, new_count = 2 } })
      assert.same({
        { line = 5, kind = "change" },
        { line = 6, kind = "change" },
      }, marks)
    end)

    it("clamps a pure delete at the top of the file to line 1", function()
      local marks = signs.marks_for({ { old_start = 1, old_count = 2, new_start = 0, new_count = 0 } })
      assert.same({ { line = 1, kind = "delete" } }, marks)
    end)

    it("marks a pure delete elsewhere at its new-side anchor line", function()
      local marks = signs.marks_for({ { old_start = 10, old_count = 1, new_start = 8, new_count = 0 } })
      assert.same({ { line = 8, kind = "delete" } }, marks)
    end)

    it("handles multiple hunks of mixed kinds in order", function()
      local marks = signs.marks_for({
        { old_start = 1, old_count = 0, new_start = 1, new_count = 1 },
        { old_start = 5, old_count = 1, new_start = 5, new_count = 1 },
        { old_start = 20, old_count = 3, new_start = 18, new_count = 0 },
      })
      assert.same({
        { line = 1, kind = "add" },
        { line = 5, kind = "change" },
        { line = 18, kind = "delete" },
      }, marks)
    end)

    it("returns an empty list when there are no hunks", function()
      assert.same({}, signs.marks_for({}))
      assert.same({}, signs.marks_for(nil))
    end)
  end)

  describe("apply / clear", function()
    local ns = vim.api.nvim_create_namespace("git-trace-review")
    local buf

    before_each(function()
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "l1", "l2", "l3", "l4", "l5" })
    end)

    after_each(function()
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)

    local function sign_marks(bufnr)
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
      local out = {}
      for _, m in ipairs(marks) do
        -- nvim right-pads single-character sign_text to 2 display cells.
        table.insert(out, { line = m[2] + 1, sign_text = vim.trim(m[4].sign_text), sign_hl_group = m[4].sign_hl_group })
      end
      table.sort(out, function(a, b)
        return a.line < b.line
      end)
      return out
    end

    it("places extmarks with sign text and highlight group for each mark", function()
      signs.apply(buf, {
        { old_start = 1, old_count = 0, new_start = 1, new_count = 1 },
        { old_start = 3, old_count = 1, new_start = 3, new_count = 1 },
      })
      assert.same({
        { line = 1, sign_text = "+", sign_hl_group = "GitTraceReviewAdd" },
        { line = 3, sign_text = "~", sign_hl_group = "GitTraceReviewChange" },
      }, sign_marks(buf))
    end)

    it("places a delete mark with its sign text and highlight group", function()
      signs.apply(buf, { { old_start = 4, old_count = 1, new_start = 3, new_count = 0 } })
      assert.same({ { line = 3, sign_text = "_", sign_hl_group = "GitTraceReviewDelete" } }, sign_marks(buf))
    end)

    it("does not duplicate marks when re-applied", function()
      local hunks = { { old_start = 1, old_count = 0, new_start = 1, new_count = 1 } }
      signs.apply(buf, hunks)
      signs.apply(buf, hunks)
      assert.equals(1, #sign_marks(buf))
    end)

    it("clears all marks", function()
      signs.apply(buf, { { old_start = 1, old_count = 0, new_start = 1, new_count = 1 } })
      signs.clear(buf)
      assert.equals(0, #sign_marks(buf))
    end)

    it("does not error when applying to an invalid buffer", function()
      local bad = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_delete(bad, { force = true })
      assert.has_no.errors(function()
        signs.apply(bad, { { old_start = 1, old_count = 0, new_start = 1, new_count = 1 } })
      end)
    end)

    it("does not error when clearing an invalid buffer", function()
      local bad = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_delete(bad, { force = true })
      assert.has_no.errors(function()
        signs.clear(bad)
      end)
    end)

    it("does not error when a hunk falls past the end of the buffer", function()
      assert.has_no.errors(function()
        signs.apply(buf, { { old_start = 1, old_count = 0, new_start = 100, new_count = 1 } })
      end)
    end)
  end)

  describe("next_hunk / prev_hunk", function()
    local win, buf
    local notifications
    local orig_notify

    local hunks = {
      { old_start = 1, old_count = 0, new_start = 2, new_count = 1 },
      { old_start = 5, old_count = 1, new_start = 5, new_count = 1 },
      { old_start = 9, old_count = 1, new_start = 9, new_count = 1 },
    }

    before_each(function()
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "l1", "l2", "l3", "l4", "l5", "l6", "l7", "l8", "l9", "l10" })
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      notifications = {}
      orig_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end
    end)

    after_each(function()
      vim.notify = orig_notify
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)

    it("jumps to the next hunk after the cursor", function()
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      signs.next_hunk(win, hunks)
      assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(win))
    end)

    it("jumps to the following hunk when already on a hunk line", function()
      vim.api.nvim_win_set_cursor(win, { 2, 0 })
      signs.next_hunk(win, hunks)
      assert.same({ 5, 0 }, vim.api.nvim_win_get_cursor(win))
    end)

    it("wraps around to the first hunk from past the last", function()
      vim.api.nvim_win_set_cursor(win, { 9, 0 })
      signs.next_hunk(win, hunks)
      assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(win))
    end)

    it("jumps to the previous hunk before the cursor", function()
      vim.api.nvim_win_set_cursor(win, { 9, 0 })
      signs.prev_hunk(win, hunks)
      assert.same({ 5, 0 }, vim.api.nvim_win_get_cursor(win))
    end)

    it("wraps around to the last hunk from before the first", function()
      vim.api.nvim_win_set_cursor(win, { 2, 0 })
      signs.prev_hunk(win, hunks)
      assert.same({ 9, 0 }, vim.api.nvim_win_get_cursor(win))
    end)

    it("notifies and does nothing when there are no hunks (next_hunk)", function()
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      signs.next_hunk(win, {})
      assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(win))
      assert.equals(1, #notifications)
      assert.equals(vim.log.levels.INFO, notifications[1].level)
      assert.matches("no hunks", notifications[1].msg)
    end)

    it("notifies and does nothing when there are no hunks (prev_hunk)", function()
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      signs.prev_hunk(win, nil)
      assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(win))
      assert.equals(1, #notifications)
      assert.matches("no hunks", notifications[1].msg)
    end)
  end)

  describe("integration with review.ui.diff", function()
    local ui_diff = require("git-trace.review.ui.diff")
    local review_git = require("git-trace.review.git")
    local ns = vim.api.nvim_create_namespace("git-trace-review")
    local WT = "/gittrace-signs-test-wt"
    local orig = {}

    local function make_session(files)
      local files_by_path = {}
      for _, f in ipairs(files) do
        files_by_path[WT .. "/" .. f.path] = f
      end
      return {
        pr = { number = 9 },
        repo_root = "/repo",
        worktree = WT,
        merge_base = "deadbeef1234567890",
        files = files,
        files_by_path = files_by_path,
        diff_enabled = false,
      }
    end

    local function open_file(relpath, lines)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, WT .. "/" .. relpath)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "head1", "head2" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.w[win].git_trace_attached = nil
      return win, buf
    end

    local function sign_count(bufnr)
      return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
    end

    before_each(function()
      orig.show_file = review_git.show_file
      orig.diff_hunks = review_git.diff_hunks
      orig.notify = vim.notify
      vim.notify = function() end
    end)

    after_each(function()
      review_git.show_file = orig.show_file
      review_git.diff_hunks = orig.diff_hunks
      vim.notify = orig.notify
      pcall(vim.cmd, "silent! only")
      pcall(vim.cmd, "silent! diffoff!")
      pcall(vim.cmd, "silent! %bwipeout!")
    end)

    it("applies signs after showing a single-file view", function()
      local session = make_session({ { path = "a.lua", status = "M", binary = false } })
      local file = session.files[1]
      review_git.diff_hunks = function(_, _, _, _, cb)
        cb({ { old_start = 1, old_count = 1, new_start = 1, new_count = 1 } }, nil)
      end
      local win, buf = open_file("a.lua", { "head1" })

      ui_diff.attach(session, file, win)

      assert.equals(1, sign_count(buf))
    end)

    it("clears signs when switching to diff view", function()
      local session = make_session({ { path = "a.lua", status = "M", binary = false } })
      local file = session.files[1]
      review_git.diff_hunks = function(_, _, _, _, cb)
        cb({ { old_start = 1, old_count = 1, new_start = 1, new_count = 1 } }, nil)
      end
      review_git.show_file = function(_, _, _, cb)
        cb({ "base1" }, nil)
      end
      local win, buf = open_file("a.lua", { "head1" })

      ui_diff.attach(session, file, win)
      assert.equals(1, sign_count(buf))

      ui_diff.toggle(session)
      assert.is_true(session.diff_enabled)
      assert.equals(0, sign_count(buf))
    end)

    it("re-applies signs when toggling back to single view", function()
      local session = make_session({ { path = "a.lua", status = "M", binary = false } })
      local file = session.files[1]
      review_git.diff_hunks = function(_, _, _, _, cb)
        cb({ { old_start = 1, old_count = 1, new_start = 1, new_count = 1 } }, nil)
      end
      review_git.show_file = function(_, _, _, cb)
        cb({ "base1" }, nil)
      end
      local win, buf = open_file("a.lua", { "head1" })

      ui_diff.attach(session, file, win)
      ui_diff.toggle(session) -- -> diff
      ui_diff.toggle(session) -- -> single

      assert.is_false(session.diff_enabled)
      assert.equals(1, sign_count(buf))
    end)

    it("does not apply signs to a binary file view", function()
      local session = make_session({ { path = "img.png", status = "M", binary = true } })
      local file = session.files[1]
      local called = false
      review_git.diff_hunks = function(_, _, _, _, cb)
        called = true
        cb({}, nil)
      end
      local win, buf = open_file("img.png", { "data" })

      ui_diff.show_single(session, file, win)

      assert.is_false(called)
      assert.equals(0, sign_count(buf))
    end)

    it("does not apply signs to a deleted file view", function()
      local session = make_session({ { path = "gone.lua", status = "D", binary = false } })
      local file = session.files[1]
      local called = false
      review_git.diff_hunks = function(_, _, _, _, cb)
        called = true
        cb({}, nil)
      end
      local win, buf = open_file("gone.lua", { "" })

      ui_diff.show_single(session, file, win)

      assert.is_false(called)
      assert.equals(0, sign_count(buf))
    end)

    it("does nothing when the window is gone before the hunk fetch resolves", function()
      local session = make_session({ { path = "a.lua", status = "M", binary = false } })
      local file = session.files[1]
      local pending
      review_git.diff_hunks = function(_, _, _, _, cb)
        pending = cb
      end

      vim.cmd("vsplit")
      local win, buf = open_file("a.lua", { "head1" })

      ui_diff.show_single(session, file, win)
      assert.is_not_nil(pending)

      vim.api.nvim_win_close(win, true)

      assert.has_no.errors(function()
        pending({ { old_start = 1, old_count = 1, new_start = 1, new_count = 1 } }, nil)
      end)
    end)

    it("re-fetches hunks and re-applies signs on BufReadPost refresh", function()
      local session = make_session({ { path = "a.lua", status = "M", binary = false } })
      local file = session.files[1]
      local fetch_count = 0
      review_git.diff_hunks = function(_, _, _, _, cb)
        fetch_count = fetch_count + 1
        cb({ { old_start = 1, old_count = 1, new_start = 1, new_count = 1 } }, nil)
      end
      local win, buf = open_file("a.lua", { "head1" })

      ui_diff.attach(session, file, win)
      assert.equals(1, fetch_count)

      ui_diff.refresh_signs(session, file, buf)

      assert.equals(2, fetch_count)
      assert.equals(1, sign_count(buf))
    end)

    it("does not re-fetch on refresh_signs while in diff view", function()
      local session = make_session({ { path = "a.lua", status = "M", binary = false } })
      session.diff_enabled = true
      local file = session.files[1]
      local called = false
      review_git.diff_hunks = function(_, _, _, _, cb)
        called = true
        cb({}, nil)
      end
      review_git.show_file = function(_, _, _, cb)
        cb({ "base1" }, nil)
      end
      local win, buf = open_file("a.lua", { "head1" })

      ui_diff.attach(session, file, win)
      ui_diff.refresh_signs(session, file, buf)

      assert.is_false(called)
    end)
  end)
end)
