local worktree = require("git-trace.review.worktree")
local review_git = require("git-trace.review.git")
local config = require("git-trace.config")

describe("review.worktree", function()
  describe("repo_id", function()
    it("derives a stable id from a GitHub remote and repo root hash", function()
      local root = "/home/me/git-trace.nvim"
      local id = worktree.repo_id("git@github.com:inari111/git-trace.nvim.git", root)
      assert.equals("inari111__git-trace.nvim-" .. vim.fn.sha256(root):sub(1, 8), id)
    end)

    it("sanitizes the directory name when the remote cannot be parsed", function()
      local root = "/home/me/my repo!"
      local id = worktree.repo_id("https://gitlab.com/foo/bar.git", root)
      assert.equals("my_repo_-" .. vim.fn.sha256(root):sub(1, 8), id)
    end)

    it("falls back to the directory name for a nil remote", function()
      local root = "/home/me/plain"
      local id = worktree.repo_id(nil, root)
      assert.equals("plain-" .. vim.fn.sha256(root):sub(1, 8), id)
    end)

    it("produces different ids for different clones of the same repo", function()
      local remote = "git@github.com:inari111/git-trace.nvim.git"
      assert.not_equals(worktree.repo_id(remote, "/clone/a"), worktree.repo_id(remote, "/clone/b"))
    end)
  end)

  describe("worktree_path", function()
    it("joins base dir, repo id and pr number", function()
      assert.equals("/base/repo-id/pr-42", worktree.worktree_path("/base", "repo-id", 42))
    end)
  end)

  describe("ensure", function()
    local originals = {}
    local base_dir = "/wt-base"
    local remote = "git@github.com:inari111/git-trace.nvim.git"
    local root = "/repo"

    before_each(function()
      originals.worktree_dir = config.values.review.worktree_dir
      originals.mkdir = vim.fn.mkdir
      originals.isdirectory = vim.fn.isdirectory
      originals.delete = vim.fn.delete
      originals.fetch_pr = review_git.fetch_pr
      originals.worktree_list = review_git.worktree_list
      originals.worktree_checkout_detach = review_git.worktree_checkout_detach
      originals.worktree_prune = review_git.worktree_prune
      originals.worktree_add = review_git.worktree_add

      config.values.review.worktree_dir = base_dir
      vim.fn.mkdir = function() return 1 end
      vim.fn.isdirectory = function() return 0 end
      vim.fn.delete = function() return 0 end
      review_git.fetch_pr = function(_, _, _, cb) cb(true, nil) end
    end)

    after_each(function()
      config.values.review.worktree_dir = originals.worktree_dir
      vim.fn.mkdir = originals.mkdir
      vim.fn.isdirectory = originals.isdirectory
      vim.fn.delete = originals.delete
      review_git.fetch_pr = originals.fetch_pr
      review_git.worktree_list = originals.worktree_list
      review_git.worktree_checkout_detach = originals.worktree_checkout_detach
      review_git.worktree_prune = originals.worktree_prune
      review_git.worktree_add = originals.worktree_add
    end)

    local function expected_path(pr)
      return worktree.worktree_path(base_dir, worktree.repo_id(remote, root), pr)
    end

    it("checks out an existing worktree in place", function()
      local path = expected_path(42)
      review_git.worktree_list = function(_, cb)
        cb({ { path = path } }, nil)
      end
      local checkout_args
      review_git.worktree_checkout_detach = function(p, ref, cb)
        checkout_args = { p, ref }
        cb(true, nil)
      end
      local add_called = false
      review_git.worktree_add = function()
        add_called = true
      end

      local received_path, received_err
      worktree.ensure(root, remote, 42, "main", function(p, err)
        received_path = p
        received_err = err
      end)

      assert.same({ path, "refs/git-trace/pr/42" }, checkout_args)
      assert.is_false(add_called)
      assert.equals(path, received_path)
      assert.is_nil(received_err)
    end)

    it("prunes and adds a new worktree when not registered", function()
      review_git.worktree_list = function(_, cb)
        cb({}, nil)
      end
      local prune_called = false
      review_git.worktree_prune = function(_, cb)
        prune_called = true
        cb(true, nil)
      end
      local add_args
      review_git.worktree_add = function(p, ref, cwd, cb)
        add_args = { p, ref, cwd }
        cb(true, nil)
      end
      local checkout_called = false
      review_git.worktree_checkout_detach = function()
        checkout_called = true
      end

      local received_path
      worktree.ensure(root, remote, 42, "main", function(p)
        received_path = p
      end)

      assert.is_true(prune_called)
      assert.same({ expected_path(42), "refs/git-trace/pr/42", root }, add_args)
      assert.is_false(checkout_called)
      assert.equals(expected_path(42), received_path)
    end)

    it("deletes a stale directory and retries add once", function()
      review_git.worktree_list = function(_, cb)
        cb({}, nil)
      end
      review_git.worktree_prune = function(_, cb)
        cb(true, nil)
      end
      vim.fn.isdirectory = function()
        return 1
      end
      local delete_calls = 0
      vim.fn.delete = function()
        delete_calls = delete_calls + 1
        return 0
      end
      local add_calls = 0
      review_git.worktree_add = function(_, _, _, cb)
        add_calls = add_calls + 1
        if add_calls == 1 then
          cb(nil, "already exists")
        else
          cb(true, nil)
        end
      end

      local received_path, received_err
      worktree.ensure(root, remote, 42, "main", function(p, err)
        received_path = p
        received_err = err
      end)

      assert.equals(2, add_calls)
      assert.equals(1, delete_calls)
      assert.equals(expected_path(42), received_path)
      assert.is_nil(received_err)
    end)

    it("fails when the retried add also fails", function()
      review_git.worktree_list = function(_, cb)
        cb({}, nil)
      end
      review_git.worktree_prune = function(_, cb)
        cb(true, nil)
      end
      vim.fn.isdirectory = function()
        return 1
      end
      review_git.worktree_add = function(_, _, _, cb)
        cb(nil, "still failing")
      end

      local received_path, received_err
      worktree.ensure(root, remote, 42, "main", function(p, err)
        received_path = p
        received_err = err
      end)

      assert.is_nil(received_path)
      assert.equals("still failing", received_err)
    end)

    it("matches an existing worktree registered under a symlinked base dir", function()
      -- worktree_dir points at a symlink; `git worktree list` reports the
      -- resolved realpath, so a raw string compare would miss the match.
      -- before_each stubs vim.fn.mkdir/delete, so use the real ones for setup.
      local scratch = vim.fn.tempname()
      originals.mkdir(scratch .. "/real-base", "p")
      vim.fn.system({ "ln", "-s", scratch .. "/real-base", scratch .. "/link-base" })
      config.values.review.worktree_dir = scratch .. "/link-base"

      local resolved_wt =
        worktree.worktree_path(scratch .. "/real-base", worktree.repo_id(remote, root), 42)
      review_git.worktree_list = function(_, cb)
        cb({ { path = resolved_wt } }, nil)
      end
      local checkout_called = false
      review_git.worktree_checkout_detach = function(_, _, cb)
        checkout_called = true
        cb(true, nil)
      end
      local add_called = false
      review_git.worktree_add = function()
        add_called = true
      end

      local received_path
      worktree.ensure(root, remote, 42, "main", function(p)
        received_path = p
      end)

      assert.is_true(checkout_called)
      assert.is_false(add_called)
      assert.equals(worktree.worktree_path(scratch .. "/link-base", worktree.repo_id(remote, root), 42), received_path)

      originals.delete(scratch, "rf")
    end)

    it("propagates a fetch error without listing worktrees", function()
      review_git.fetch_pr = function(_, _, _, cb)
        cb(nil, "fetch boom")
      end
      local list_called = false
      review_git.worktree_list = function(_, cb)
        list_called = true
        cb({}, nil)
      end

      local received_path, received_err
      worktree.ensure(root, remote, 42, "main", function(p, err)
        received_path = p
        received_err = err
      end)

      assert.is_false(list_called)
      assert.is_nil(received_path)
      assert.equals("fetch boom", received_err)
    end)
  end)

  describe("clean", function()
    local originals = {}

    before_each(function()
      originals.worktree_dir = config.values.review.worktree_dir
      originals.worktree_list = review_git.worktree_list
      originals.worktree_remove = review_git.worktree_remove
      originals.worktree_prune = review_git.worktree_prune
      originals.delete_review_refs = review_git.delete_review_refs
      config.values.review.worktree_dir = "/wt-base"
    end)

    after_each(function()
      config.values.review.worktree_dir = originals.worktree_dir
      review_git.worktree_list = originals.worktree_list
      review_git.worktree_remove = originals.worktree_remove
      review_git.worktree_prune = originals.worktree_prune
      review_git.delete_review_refs = originals.delete_review_refs
    end)

    it("removes only worktrees under the base dir, then prunes and deletes refs", function()
      review_git.worktree_list = function(_, cb)
        cb({
          { path = "/wt-base/repo/pr-1" },
          { path = "/wt-base/repo/pr-2" },
          { path = "/elsewhere/pr-9" },
          { path = "/repo" },
        }, nil)
      end
      local removed = {}
      review_git.worktree_remove = function(p, _, cb)
        table.insert(removed, p)
        cb(true, nil)
      end
      local prune_called = false
      review_git.worktree_prune = function(_, cb)
        prune_called = true
        cb(true, nil)
      end
      local refs_deleted = false
      review_git.delete_review_refs = function(_, cb)
        refs_deleted = true
        cb(true, nil)
      end

      local count, err
      worktree.clean("/repo", function(c, e)
        count = c
        err = e
      end)

      assert.same({ "/wt-base/repo/pr-1", "/wt-base/repo/pr-2" }, removed)
      assert.is_true(prune_called)
      assert.is_true(refs_deleted)
      assert.equals(2, count)
      assert.is_nil(err)
    end)

    it("still prunes and deletes refs when nothing matches", function()
      review_git.worktree_list = function(_, cb)
        cb({ { path = "/repo" } }, nil)
      end
      review_git.worktree_remove = function()
        error("should not remove")
      end
      local prune_called = false
      review_git.worktree_prune = function(_, cb)
        prune_called = true
        cb(true, nil)
      end
      local refs_deleted = false
      review_git.delete_review_refs = function(_, cb)
        refs_deleted = true
        cb(true, nil)
      end

      local count
      worktree.clean("/repo", function(c)
        count = c
      end)

      assert.is_true(prune_called)
      assert.is_true(refs_deleted)
      assert.equals(0, count)
    end)
  end)
end)
