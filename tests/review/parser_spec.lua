local parser = require("git-trace.review.parser")

describe("review.parser", function()
  describe("parse_hunks", function()
    it("defaults count to 1 when omitted", function()
      local hunks = parser.parse_hunks("@@ -3 +3 @@\n-old\n+new\n")
      assert.equals(1, #hunks)
      assert.same({ old_start = 3, old_count = 1, new_start = 3, new_count = 1 }, hunks[1])
    end)

    it("keeps an explicit count of 0 for pure deletions", function()
      local hunks = parser.parse_hunks("@@ -5,2 +4,0 @@\n-a\n-b\n")
      assert.equals(1, #hunks)
      assert.same({ old_start = 5, old_count = 2, new_start = 4, new_count = 0 }, hunks[1])
    end)

    it("parses multiple hunks", function()
      local diff = "@@ -1,2 +1,3 @@\n context\n-old\n+new1\n+new2\n@@ -10,1 +11,1 @@\n-x\n+y\n"
      local hunks = parser.parse_hunks(diff)
      assert.equals(2, #hunks)
      assert.same({ old_start = 1, old_count = 2, new_start = 1, new_count = 3 }, hunks[1])
      assert.same({ old_start = 10, old_count = 1, new_start = 11, new_count = 1 }, hunks[2])
    end)

    it("returns an empty list for empty or unrelated text", function()
      assert.same({}, parser.parse_hunks(""))
      assert.same({}, parser.parse_hunks(nil))
      assert.same({}, parser.parse_hunks("diff --git a/foo b/foo\nindex abc..def 100644\n"))
    end)
  end)

  describe("parse_name_status", function()
    it("parses A/M/D/T entries", function()
      local output = "A\0added.txt\0M\0modified.txt\0D\0deleted.txt\0T\0typechanged.txt\0"
      local entries = parser.parse_name_status(output)
      assert.equals(4, #entries)
      assert.same({ status = "A", path = "added.txt" }, entries[1])
      assert.same({ status = "M", path = "modified.txt" }, entries[2])
      assert.same({ status = "D", path = "deleted.txt" }, entries[3])
      assert.same({ status = "T", path = "typechanged.txt" }, entries[4])
    end)

    it("parses R100-style rename as a two-path entry normalized to R", function()
      local output = "R100\0old.txt\0new.txt\0"
      local entries = parser.parse_name_status(output)
      assert.equals(1, #entries)
      assert.same({ status = "R", path = "new.txt", old_path = "old.txt" }, entries[1])
    end)

    it("parses multiple mixed entries with a trailing NUL", function()
      local output = "A\0added.txt\0R079\0old.txt\0new.txt\0M\0modified.txt\0"
      local entries = parser.parse_name_status(output)
      assert.equals(3, #entries)
      assert.same({ status = "A", path = "added.txt" }, entries[1])
      assert.same({ status = "R", path = "new.txt", old_path = "old.txt" }, entries[2])
      assert.same({ status = "M", path = "modified.txt" }, entries[3])
    end)

    it("returns an empty list for empty output", function()
      assert.same({}, parser.parse_name_status(""))
      assert.same({}, parser.parse_name_status(nil))
    end)
  end)

  describe("parse_numstat", function()
    it("parses regular add/delete counts", function()
      local output = "3\t1\tmodified.txt\0"
      local entries = parser.parse_numstat(output)
      assert.equals(1, #entries)
      assert.same({ additions = 3, deletions = 1, path = "modified.txt" }, entries[1])
    end)

    it("parses binary files with nil additions/deletions", function()
      local output = "-\t-\tbinary.bin\0"
      local entries = parser.parse_numstat(output)
      assert.equals(1, #entries)
      assert.equals("binary.bin", entries[1].path)
      assert.is_nil(entries[1].additions)
      assert.is_nil(entries[1].deletions)
    end)

    it("parses rename entries with old and new path", function()
      local output = "1\t0\t\0oldname.txt\0newname.txt\0"
      local entries = parser.parse_numstat(output)
      assert.equals(1, #entries)
      assert.same({ additions = 1, deletions = 0, old_path = "oldname.txt", path = "newname.txt" }, entries[1])
    end)

    it("parses multiple entries", function()
      local output = "1\t0\tadded.txt\0-\t-\tbinary.bin\0"
      local entries = parser.parse_numstat(output)
      assert.equals(2, #entries)
      assert.equals("added.txt", entries[1].path)
      assert.equals("binary.bin", entries[2].path)
    end)

    it("returns an empty list for empty output", function()
      assert.same({}, parser.parse_numstat(""))
      assert.same({}, parser.parse_numstat(nil))
    end)
  end)

  describe("merge_changed_files", function()
    it("merges matching name-status and numstat entries", function()
      local name_status = { { status = "M", path = "modified.txt" } }
      local numstat = { { additions = 3, deletions = 1, path = "modified.txt" } }
      local files = parser.merge_changed_files(name_status, numstat)
      assert.equals(1, #files)
      assert.same({
        path = "modified.txt",
        old_path = nil,
        status = "M",
        additions = 3,
        deletions = 1,
        binary = false,
      }, files[1])
    end)

    it("marks binary when numstat has nil counts for an existing entry", function()
      local name_status = { { status = "M", path = "binary.bin" } }
      local numstat = { { path = "binary.bin" } }
      local files = parser.merge_changed_files(name_status, numstat)
      assert.equals(1, #files)
      assert.is_true(files[1].binary)
      assert.is_nil(files[1].additions)
      assert.is_nil(files[1].deletions)
    end)

    it("leaves additions/deletions nil and binary false when numstat entry is missing", function()
      local name_status = { { status = "A", path = "added.txt" } }
      local files = parser.merge_changed_files(name_status, {})
      assert.equals(1, #files)
      assert.is_nil(files[1].additions)
      assert.is_nil(files[1].deletions)
      assert.is_false(files[1].binary)
    end)

    it("matches renames by the new path", function()
      local name_status = { { status = "R", path = "new.txt", old_path = "old.txt" } }
      local numstat = { { additions = 2, deletions = 1, old_path = "old.txt", path = "new.txt" } }
      local files = parser.merge_changed_files(name_status, numstat)
      assert.equals(1, #files)
      assert.equals("new.txt", files[1].path)
      assert.equals("old.txt", files[1].old_path)
      assert.equals(2, files[1].additions)
      assert.equals(1, files[1].deletions)
    end)
  end)

  describe("parse_worktree_list", function()
    it("parses an entry with a branch", function()
      local output = "worktree /repo\nHEAD abc123\nbranch refs/heads/main\n"
      local entries = parser.parse_worktree_list(output)
      assert.equals(1, #entries)
      assert.same({ path = "/repo", head = "abc123", branch = "refs/heads/main", detached = false }, entries[1])
    end)

    it("parses a detached entry", function()
      local output = "worktree /repo/wt-pr-1\nHEAD def456\ndetached\n"
      local entries = parser.parse_worktree_list(output)
      assert.equals(1, #entries)
      assert.same({ path = "/repo/wt-pr-1", head = "def456", detached = true }, entries[1])
    end)

    it("parses multiple entries separated by blank lines", function()
      local output = "worktree /repo\nHEAD abc123\nbranch refs/heads/main\n\n"
        .. "worktree /repo/wt-pr-1\nHEAD def456\ndetached\n\n"
      local entries = parser.parse_worktree_list(output)
      assert.equals(2, #entries)
      assert.equals("/repo", entries[1].path)
      assert.is_false(entries[1].detached)
      assert.equals("/repo/wt-pr-1", entries[2].path)
      assert.is_true(entries[2].detached)
    end)

    it("returns an empty list for empty output", function()
      assert.same({}, parser.parse_worktree_list(""))
      assert.same({}, parser.parse_worktree_list(nil))
    end)
  end)
end)
