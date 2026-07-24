local qflist = require("git-trace.review.ui.qflist")

describe("review.ui.qflist", function()
  describe("build_items", function()
    local wt = "/wt"

    it("formats a modified file", function()
      local items = qflist.build_items({
        { path = "lua/git-trace/git.lua", status = "M", additions = 12, deletions = 3, binary = false },
      }, wt)
      assert.equals(1, #items)
      assert.same({
        filename = "/wt/lua/git-trace/git.lua",
        lnum = 1,
        text = "M +12 -3  lua/git-trace/git.lua",
      }, items[1])
    end)

    it("formats an added file", function()
      local items = qflist.build_items({
        { path = "new.lua", status = "A", additions = 5, deletions = 0, binary = false },
      }, wt)
      assert.equals("A +5 -0  new.lua", items[1].text)
      assert.equals("/wt/new.lua", items[1].filename)
    end)

    it("formats a deleted file with the worktree path", function()
      local items = qflist.build_items({
        { path = "gone.lua", status = "D", additions = 0, deletions = 8, binary = false },
      }, wt)
      assert.equals("D +0 -8  gone.lua", items[1].text)
      assert.equals("/wt/gone.lua", items[1].filename)
    end)

    it("shows the rename arrow but points filename at the new path", function()
      local items = qflist.build_items({
        { path = "new.lua", old_path = "old.lua", status = "R", additions = 5, deletions = 1, binary = false },
      }, wt)
      assert.equals("R +5 -1  old.lua -> new.lua", items[1].text)
      assert.equals("/wt/new.lua", items[1].filename)
    end)

    it("marks binary files with dashes and a suffix", function()
      local items = qflist.build_items({
        { path = "image.png", status = "M", additions = nil, deletions = nil, binary = true },
      }, wt)
      assert.equals("M +- --  image.png [binary]", items[1].text)
      assert.equals("/wt/image.png", items[1].filename)
    end)
  end)
end)
