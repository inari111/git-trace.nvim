local config = require("git-trace.config")
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

  describe("parse_pr_view", function()
    it("parses a valid PR view JSON payload", function()
      local json = [[{
        "number": 42,
        "title": "Add feature",
        "url": "https://github.com/user/repo/pull/42",
        "state": "OPEN",
        "baseRefName": "main",
        "headRefOid": "abc123"
      }]]
      local pr = github.parse_pr_view(json)
      assert.is_not_nil(pr)
      assert.equals(42, pr.number)
      assert.equals("Add feature", pr.title)
      assert.equals("https://github.com/user/repo/pull/42", pr.url)
      assert.equals("OPEN", pr.state)
      assert.equals("main", pr.base_ref)
      assert.equals("abc123", pr.head_oid)
    end)

    it("returns nil when a required field is missing", function()
      local json = '{"title":"Add feature","url":"https://github.com/user/repo/pull/42"}'
      assert.is_nil(github.parse_pr_view(json))
    end)

    it("returns nil for invalid JSON", function()
      assert.is_nil(github.parse_pr_view("not json"))
    end)

    it("returns nil for empty string", function()
      assert.is_nil(github.parse_pr_view(""))
      assert.is_nil(github.parse_pr_view(nil))
    end)
  end)

  describe("pr_view", function()
    local original_system
    local original_schedule
    local captured_cmd
    local captured_opts

    before_each(function()
      original_system = vim.system
      original_schedule = vim.schedule
      captured_cmd = nil
      captured_opts = nil
      vim.schedule = function(fn)
        fn()
      end
    end)

    after_each(function()
      vim.system = original_system
      vim.schedule = original_schedule
    end)

    it("runs gh pr view with the expected args and parses the result", function()
      vim.system = function(cmd, opts, cb)
        captured_cmd = cmd
        captured_opts = opts
        cb({ code = 0, stdout = '{"number":42,"baseRefName":"main"}', stderr = "" })
      end

      local received_pr, received_err
      github.pr_view(42, "/some/repo", function(pr, err)
        received_pr = pr
        received_err = err
      end)

      assert.same({ "gh", "pr", "view", "42", "--json", "number,title,url,state,baseRefName,headRefOid" }, captured_cmd)
      assert.equals("/some/repo", captured_opts.cwd)
      assert.is_nil(received_err)
      assert.equals(42, received_pr.number)
      assert.equals("main", received_pr.base_ref)
    end)

    it("translates auth errors into a friendly message", function()
      vim.system = function(_, _, cb)
        cb({ code = 1, stdout = "", stderr = "gh: To use GitHub CLI, please run: gh auth login" })
      end

      local received_err
      github.pr_view(42, "/some/repo", function(_, err)
        received_err = err
      end)

      assert.equals("gh auth login required. Run: gh auth login", received_err)
    end)
  end)

  describe("list_open_prs", function()
    local original_system
    local original_schedule
    local captured_cmd

    before_each(function()
      original_system = vim.system
      original_schedule = vim.schedule
      captured_cmd = nil
      vim.schedule = function(fn)
        fn()
      end
    end)

    after_each(function()
      vim.system = original_system
      vim.schedule = original_schedule
      config.apply({})
    end)

    it("runs gh pr list with the configured limit and parses the result", function()
      config.apply({ review = { pr_list_limit = 5 } })
      vim.system = function(cmd, _, cb)
        captured_cmd = cmd
        cb({ code = 0, stdout = '[{"number":1,"title":"A","author":{"login":"alice"}}]', stderr = "" })
      end

      local received_prs, received_err
      github.list_open_prs("/some/repo", function(prs, err)
        received_prs = prs
        received_err = err
      end)

      assert.same(
        { "gh", "pr", "list", "--state", "open", "--json", "number,title,author", "--limit", "5" },
        captured_cmd
      )
      assert.is_nil(received_err)
      assert.equals(1, #received_prs)
      assert.equals("alice", received_prs[1].author.login)
    end)

    it("translates auth errors into a friendly message", function()
      vim.system = function(_, _, cb)
        cb({ code = 1, stdout = "", stderr = "auth required" })
      end

      local received_err
      github.list_open_prs("/some/repo", function(_, err)
        received_err = err
      end)

      assert.equals("gh auth login required. Run: gh auth login", received_err)
    end)
  end)
end)
