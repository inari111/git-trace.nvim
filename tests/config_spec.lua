local config = require("git-trace.config")

describe("config", function()
  after_each(function()
    config.apply({})
  end)

  describe("apply", function()
    it("uses defaults when no opts provided", function()
      local c = config.apply()
      assert.equals("merged", c.pr_state)
      assert.equals("gh", c.gh_path)
      assert.equals("git", c.git_path)
    end)

    it("merges user opts with defaults", function()
      local c = config.apply({ pr_state = "all" })
      assert.equals("all", c.pr_state)
      assert.equals("gh", c.gh_path)
    end)

    it("resets invalid pr_state to default", function()
      local orig_notify = vim.notify
      vim.notify = function() end
      local c = config.apply({ pr_state = "invalid" })
      vim.notify = orig_notify
      assert.equals("merged", c.pr_state)
    end)

    it("fills in review defaults", function()
      local c = config.apply()
      assert.is_nil(c.review.worktree_dir)
      assert.equals(30, c.review.pr_list_limit)
      assert.is_true(c.review.open_qf)
      assert.equals("<leader>rd", c.review.keymaps.toggle_diff)
      assert.equals("]f", c.review.keymaps.next_file)
      assert.equals("[f", c.review.keymaps.prev_file)
      assert.equals("]c", c.review.keymaps.next_hunk)
      assert.equals("[c", c.review.keymaps.prev_hunk)
      assert.equals("<leader>rq", c.review.keymaps.close)
    end)

    it("resets an invalid review.pr_list_limit to default", function()
      local orig_notify = vim.notify
      vim.notify = function() end
      local c = config.apply({ review = { pr_list_limit = -1 } })
      vim.notify = orig_notify
      assert.equals(30, c.review.pr_list_limit)
    end)

    it("resets a non-integer review.pr_list_limit to default", function()
      local orig_notify = vim.notify
      vim.notify = function() end
      local c = config.apply({ review = { pr_list_limit = "many" } })
      vim.notify = orig_notify
      assert.equals(30, c.review.pr_list_limit)
    end)

    it("allows review.keymaps = false to disable all keymaps", function()
      local c = config.apply({ review = { keymaps = false } })
      assert.is_false(c.review.keymaps)
    end)

    it("merges user review opts with defaults", function()
      local c = config.apply({ review = { pr_list_limit = 50 } })
      assert.equals(50, c.review.pr_list_limit)
      assert.is_true(c.review.open_qf)
    end)
  end)
end)
