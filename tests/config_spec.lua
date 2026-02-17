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
  end)
end)
