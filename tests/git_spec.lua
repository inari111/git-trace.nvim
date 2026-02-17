local git = require("git-trace.git")

describe("git", function()
  describe("blame_line", function()
    local original_system
    local original_schedule
    local captured_opts

    before_each(function()
      original_system = vim.system
      original_schedule = vim.schedule
      captured_opts = nil

      vim.system = function(cmd, opts, cb)
        captured_opts = opts
        cb({ code = 0, stdout = "abc123 1 1 1\nauthor Test\n", stderr = "" })
      end
      vim.schedule = function(fn)
        fn()
      end
    end)

    after_each(function()
      vim.system = original_system
      vim.schedule = original_schedule
    end)

    it("passes cwd derived from file path to vim.system", function()
      local done = false
      git.blame_line("/some/dir/file.lua", 1, function()
        done = true
      end)

      assert.is_not_nil(captured_opts)
      assert.equals("/some/dir", captured_opts.cwd)
      assert.is_true(done)
    end)
  end)

  describe("parse_blame_porcelain", function()
    it("extracts hash from porcelain output", function()
      local output = "abc1234def5678901234567890123456789012 1 1 1\nauthor Test\n"
      local hash = git.parse_blame_porcelain(output)
      assert.equals("abc1234def5678901234567890123456789012", hash)
    end)

    it("returns nil for zero hash (uncommitted)", function()
      local output = "0000000000000000000000000000000000000000 1 1 1\nauthor Test\n"
      local hash = git.parse_blame_porcelain(output)
      assert.is_nil(hash)
    end)

    it("returns nil for empty output", function()
      assert.is_nil(git.parse_blame_porcelain(""))
      assert.is_nil(git.parse_blame_porcelain(nil))
    end)
  end)
end)
