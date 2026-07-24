local review_git = require("git-trace.review.git")

describe("review.git", function()
  local original_system
  local original_schedule

  before_each(function()
    original_system = vim.system
    original_schedule = vim.schedule
    vim.schedule = function(fn)
      fn()
    end
  end)

  after_each(function()
    vim.system = original_system
    vim.schedule = original_schedule
  end)

  describe("pr_ref", function()
    it("builds the dedicated review ref name", function()
      assert.equals("refs/git-trace/pr/42", review_git.pr_ref(42))
    end)
  end)

  describe("fetch_pr", function()
    it("fetches the PR head and base branch into dedicated refs", function()
      local captured_cmd, captured_opts
      vim.system = function(cmd, opts, cb)
        captured_cmd = cmd
        captured_opts = opts
        cb({ code = 0, stdout = "", stderr = "" })
      end

      local received_ok, received_err
      review_git.fetch_pr(42, "main", "/repo", function(ok, err)
        received_ok = ok
        received_err = err
      end)

      assert.same({
        "git",
        "fetch",
        "origin",
        "+refs/pull/42/head:refs/git-trace/pr/42",
        "+refs/heads/main:refs/remotes/origin/main",
      }, captured_cmd)
      assert.equals("/repo", captured_opts.cwd)
      assert.is_true(received_ok)
      assert.is_nil(received_err)
    end)

    it("returns an error when the fetch fails", function()
      vim.system = function(_, _, cb)
        cb({ code = 1, stdout = "", stderr = "fetch failed" })
      end

      local received_ok, received_err
      review_git.fetch_pr(42, "main", "/repo", function(ok, err)
        received_ok = ok
        received_err = err
      end)

      assert.is_nil(received_ok)
      assert.equals("fetch failed", received_err)
    end)
  end)

  describe("merge_base", function()
    it("returns the trimmed merge-base sha", function()
      vim.system = function(_, _, cb)
        cb({ code = 0, stdout = "abc123\n", stderr = "" })
      end

      local received_sha
      review_git.merge_base("refs/git-trace/pr/42", "origin/main", "/repo", function(sha)
        received_sha = sha
      end)

      assert.equals("abc123", received_sha)
    end)
  end)

  describe("changed_files", function()
    it("runs name-status then numstat and merges the results", function()
      local calls = {}
      vim.system = function(cmd, opts, cb)
        table.insert(calls, { cmd = cmd, opts = opts })
        if #calls == 1 then
          cb({ code = 0, stdout = "M\0modified.txt\0", stderr = "" })
        else
          cb({ code = 0, stdout = "3\t1\tmodified.txt\0", stderr = "" })
        end
      end

      local received_files, received_err
      review_git.changed_files("base_sha", "head_sha", "/repo", function(files, err)
        received_files = files
        received_err = err
      end)

      assert.equals(2, #calls)
      assert.same({ "git", "diff", "--name-status", "-z", "-M", "base_sha", "head_sha" }, calls[1].cmd)
      assert.same({ "git", "diff", "--numstat", "-z", "-M", "base_sha", "head_sha" }, calls[2].cmd)
      assert.equals("/repo", calls[1].opts.cwd)
      assert.equals("/repo", calls[2].opts.cwd)
      assert.is_nil(received_err)
      assert.equals(1, #received_files)
      assert.same({
        path = "modified.txt",
        old_path = nil,
        status = "M",
        additions = 3,
        deletions = 1,
        binary = false,
      }, received_files[1])
    end)

    it("returns an error without calling numstat when name-status fails", function()
      local calls = 0
      vim.system = function(_, _, cb)
        calls = calls + 1
        cb({ code = 1, stdout = "", stderr = "diff failed" })
      end

      local received_files, received_err
      review_git.changed_files("base_sha", "head_sha", "/repo", function(files, err)
        received_files = files
        received_err = err
      end)

      assert.equals(1, calls)
      assert.is_nil(received_files)
      assert.equals("diff failed", received_err)
    end)
  end)

  describe("show_file", function()
    it("splits stdout into lines and drops the trailing empty element", function()
      vim.system = function(_, _, cb)
        cb({ code = 0, stdout = "line1\nline2\n", stderr = "" })
      end

      local received_lines
      review_git.show_file("abc123", "path/to/file.lua", "/repo", function(lines)
        received_lines = lines
      end)

      assert.same({ "line1", "line2" }, received_lines)
    end)
  end)

  describe("diff_hunks", function()
    it("diffs against base without an old path", function()
      local captured_cmd, captured_opts
      vim.system = function(cmd, opts, cb)
        captured_cmd = cmd
        captured_opts = opts
        cb({ code = 0, stdout = "@@ -3 +3 @@\n-a\n+b\n", stderr = "" })
      end

      local received_hunks
      review_git.diff_hunks("base_sha", "file.lua", nil, "/worktree", function(hunks)
        received_hunks = hunks
      end)

      assert.same({ "git", "diff", "-U0", "-M", "base_sha", "--", "file.lua" }, captured_cmd)
      assert.equals("/worktree", captured_opts.cwd)
      assert.equals(1, #received_hunks)
    end)

    it("includes the old path when the file was renamed", function()
      local captured_cmd
      vim.system = function(cmd, _, cb)
        captured_cmd = cmd
        cb({ code = 0, stdout = "", stderr = "" })
      end

      review_git.diff_hunks("base_sha", "new.txt", "old.txt", "/worktree", function() end)

      assert.same({ "git", "diff", "-U0", "-M", "base_sha", "--", "old.txt", "new.txt" }, captured_cmd)
    end)
  end)

  describe("worktree_add", function()
    it("adds a detached worktree at the given path and ref", function()
      local captured_cmd, captured_opts
      vim.system = function(cmd, opts, cb)
        captured_cmd = cmd
        captured_opts = opts
        cb({ code = 0, stdout = "", stderr = "" })
      end

      local received_ok
      review_git.worktree_add("/cache/pr-42", "refs/git-trace/pr/42", "/repo", function(ok)
        received_ok = ok
      end)

      assert.same({ "git", "worktree", "add", "--detach", "/cache/pr-42", "refs/git-trace/pr/42" }, captured_cmd)
      assert.equals("/repo", captured_opts.cwd)
      assert.is_true(received_ok)
    end)
  end)

  describe("worktree_checkout_detach", function()
    it("runs checkout with cwd set to the worktree path", function()
      local captured_cmd, captured_opts
      vim.system = function(cmd, opts, cb)
        captured_cmd = cmd
        captured_opts = opts
        cb({ code = 0, stdout = "", stderr = "" })
      end

      review_git.worktree_checkout_detach("/cache/pr-42", "refs/git-trace/pr/42", function() end)

      assert.same({ "git", "checkout", "--detach", "--force", "refs/git-trace/pr/42" }, captured_cmd)
      assert.equals("/cache/pr-42", captured_opts.cwd)
    end)
  end)

  describe("worktree_list", function()
    it("parses porcelain output via the parser", function()
      vim.system = function(_, _, cb)
        cb({ code = 0, stdout = "worktree /repo\nHEAD abc123\nbranch refs/heads/main\n", stderr = "" })
      end

      local received_worktrees
      review_git.worktree_list("/repo", function(worktrees)
        received_worktrees = worktrees
      end)

      assert.equals(1, #received_worktrees)
      assert.equals("/repo", received_worktrees[1].path)
    end)
  end)

  describe("worktree_remove", function()
    it("force-removes the given path", function()
      local captured_cmd
      vim.system = function(cmd, _, cb)
        captured_cmd = cmd
        cb({ code = 0, stdout = "", stderr = "" })
      end

      review_git.worktree_remove("/cache/pr-42", "/repo", function() end)

      assert.same({ "git", "worktree", "remove", "--force", "/cache/pr-42" }, captured_cmd)
    end)
  end)

  describe("worktree_prune", function()
    it("runs git worktree prune", function()
      local captured_cmd
      vim.system = function(cmd, _, cb)
        captured_cmd = cmd
        cb({ code = 0, stdout = "", stderr = "" })
      end

      review_git.worktree_prune("/repo", function() end)

      assert.same({ "git", "worktree", "prune" }, captured_cmd)
    end)
  end)

  describe("delete_review_refs", function()
    it("calls back immediately with true when there are no refs", function()
      local calls = 0
      vim.system = function(cmd, _, cb)
        calls = calls + 1
        assert.same({ "git", "for-each-ref", "--format=%(refname)", "refs/git-trace/" }, cmd)
        cb({ code = 0, stdout = "", stderr = "" })
      end

      local received_ok
      review_git.delete_review_refs("/repo", function(ok)
        received_ok = ok
      end)

      assert.equals(1, calls)
      assert.is_true(received_ok)
    end)

    it("deletes each ref found via for-each-ref using update-ref -d", function()
      local calls = {}
      vim.system = function(cmd, opts, cb)
        table.insert(calls, cmd)
        if #calls == 1 then
          cb({ code = 0, stdout = "refs/git-trace/pr/1\nrefs/git-trace/pr/2\n", stderr = "" })
        else
          cb({ code = 0, stdout = "", stderr = "" })
        end
      end

      local received_ok
      review_git.delete_review_refs("/repo", function(ok)
        received_ok = ok
      end)

      assert.equals(3, #calls)
      assert.same({ "git", "for-each-ref", "--format=%(refname)", "refs/git-trace/" }, calls[1])
      assert.same({ "git", "update-ref", "-d", "refs/git-trace/pr/1" }, calls[2])
      assert.same({ "git", "update-ref", "-d", "refs/git-trace/pr/2" }, calls[3])
      assert.is_true(received_ok)
    end)

    it("stops and returns an error if a ref deletion fails", function()
      local calls = 0
      vim.system = function(_, _, cb)
        calls = calls + 1
        if calls == 1 then
          cb({ code = 0, stdout = "refs/git-trace/pr/1\n", stderr = "" })
        else
          cb({ code = 1, stdout = "", stderr = "update-ref failed" })
        end
      end

      local received_ok, received_err
      review_git.delete_review_refs("/repo", function(ok, err)
        received_ok = ok
        received_err = err
      end)

      assert.is_nil(received_ok)
      assert.equals("update-ref failed", received_err)
    end)
  end)
end)
