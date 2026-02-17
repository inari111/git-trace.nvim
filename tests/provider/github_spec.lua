local github = require("git-trace.provider.github")

describe("provider.github", function()
  describe("parse_pr_list", function()
    it("parses valid JSON array", function()
      local json = '[{"number":42,"url":"https://github.com/user/repo/pull/42"}]'
      local prs = github.parse_pr_list(json)
      assert.is_not_nil(prs)
      assert.equals(1, #prs)
      assert.equals(42, prs[1].number)
      assert.equals("https://github.com/user/repo/pull/42", prs[1].url)
    end)

    it("parses empty array", function()
      local prs = github.parse_pr_list("[]")
      assert.is_not_nil(prs)
      assert.equals(0, #prs)
    end)

    it("returns nil for empty string", function()
      assert.is_nil(github.parse_pr_list(""))
      assert.is_nil(github.parse_pr_list(nil))
    end)

    it("returns nil for invalid JSON", function()
      assert.is_nil(github.parse_pr_list("not json"))
    end)

    it("parses multiple PRs", function()
      local json = '[{"number":1,"url":"https://github.com/u/r/pull/1"},{"number":2,"url":"https://github.com/u/r/pull/2"}]'
      local prs = github.parse_pr_list(json)
      assert.equals(2, #prs)
    end)
  end)

  describe("parse_owner_repo", function()
    it("parses SSH URL", function()
      assert.equals("user/repo", github.parse_owner_repo("git@github.com:user/repo.git"))
    end)

    it("parses HTTPS URL", function()
      assert.equals("user/repo", github.parse_owner_repo("https://github.com/user/repo.git"))
    end)

    it("parses HTTPS URL without .git", function()
      assert.equals("user/repo", github.parse_owner_repo("https://github.com/user/repo"))
    end)

    it("handles hyphens and dots in names", function()
      assert.equals("my-org/my-repo.nvim", github.parse_owner_repo("git@github.com:my-org/my-repo.nvim.git"))
    end)

    it("returns nil for non-GitHub URL", function()
      assert.is_nil(github.parse_owner_repo("git@gitlab.com:user/repo.git"))
    end)

    it("returns nil for nil input", function()
      assert.is_nil(github.parse_owner_repo(nil))
    end)
  end)

  describe("build_file_url", function()
    local remote = "git@github.com:user/repo.git"
    local hash = "abc1234"

    it("builds URL without line numbers", function()
      local url = github.build_file_url(remote, hash, "src/main.lua", nil, nil)
      assert.equals("https://github.com/user/repo/blob/abc1234/src/main.lua", url)
    end)

    it("builds URL with single line", function()
      local url = github.build_file_url(remote, hash, "src/main.lua", 10, nil)
      assert.equals("https://github.com/user/repo/blob/abc1234/src/main.lua#L10", url)
    end)

    it("builds URL with same start and end line", function()
      local url = github.build_file_url(remote, hash, "src/main.lua", 10, 10)
      assert.equals("https://github.com/user/repo/blob/abc1234/src/main.lua#L10", url)
    end)

    it("builds URL with line range", function()
      local url = github.build_file_url(remote, hash, "src/main.lua", 10, 20)
      assert.equals("https://github.com/user/repo/blob/abc1234/src/main.lua#L10-L20", url)
    end)

    it("returns nil for non-GitHub remote", function()
      local url = github.build_file_url("git@gitlab.com:user/repo.git", hash, "file.lua", nil, nil)
      assert.is_nil(url)
    end)
  end)
end)
