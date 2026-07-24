local config = require("git-trace.config")
local parser = require("git-trace.review.parser")

local M = {}

---Build the dedicated ref name used to track a fetched PR head.
---@param number integer PR number
---@return string
function M.pr_ref(number)
  return "refs/git-trace/pr/" .. number
end

---Fetch a PR head and its base branch into dedicated refs.
---@param number integer PR number
---@param base_ref string base branch name (e.g. "main")
---@param cwd string directory to run git from
---@param callback fun(ok: boolean|nil, err: string|nil)
function M.fetch_pr(number, base_ref, cwd, callback)
  local git = config.values.git_path
  local pr_refspec = ("+refs/pull/%d/head:%s"):format(number, M.pr_ref(number))
  local base_refspec = ("+refs/heads/%s:refs/remotes/origin/%s"):format(base_ref, base_ref)

  vim.system({ git, "fetch", "origin", pr_refspec, base_refspec }, { text = true, cwd = cwd }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, vim.trim(result.stderr or "git fetch failed"))
        return
      end
      callback(true, nil)
    end)
  end)
end

---Compute the merge base between two refs.
---@param ref_a string
---@param ref_b string
---@param cwd string directory to run git from
---@param callback fun(sha: string|nil, err: string|nil)
function M.merge_base(ref_a, ref_b, cwd, callback)
  local git = config.values.git_path

  vim.system({ git, "merge-base", ref_a, ref_b }, { text = true, cwd = cwd }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, vim.trim(result.stderr or "git merge-base failed"))
        return
      end
      callback(vim.trim(result.stdout), nil)
    end)
  end)
end

---Compute the changed files between two revisions by combining
---`--name-status` and `--numstat` output.
---@param base string base revision (typically the merge-base sha)
---@param head string head revision
---@param cwd string directory to run git from
---@param callback fun(files: GitTraceReviewFile[]|nil, err: string|nil)
function M.changed_files(base, head, cwd, callback)
  local git = config.values.git_path

  vim.system({ git, "diff", "--name-status", "-z", "-M", base, head }, { text = true, cwd = cwd }, function(ns_result)
    vim.schedule(function()
      if ns_result.code ~= 0 then
        callback(nil, vim.trim(ns_result.stderr or "git diff --name-status failed"))
        return
      end

      local name_status = parser.parse_name_status(ns_result.stdout)

      vim.system({ git, "diff", "--numstat", "-z", "-M", base, head }, { text = true, cwd = cwd }, function(num_result)
        vim.schedule(function()
          if num_result.code ~= 0 then
            callback(nil, vim.trim(num_result.stderr or "git diff --numstat failed"))
            return
          end

          local numstat = parser.parse_numstat(num_result.stdout)
          callback(parser.merge_changed_files(name_status, numstat), nil)
        end)
      end)
    end)
  end)
end

---Get the content of a file at a specific revision.
---@param rev string revision (sha or ref)
---@param rel_path string path relative to the repo root
---@param cwd string directory to run git from
---@param callback fun(lines: string[]|nil, err: string|nil)
function M.show_file(rev, rel_path, cwd, callback)
  local git = config.values.git_path

  vim.system({ git, "show", ("%s:%s"):format(rev, rel_path) }, { text = true, cwd = cwd }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, vim.trim(result.stderr or "git show failed"))
        return
      end
      local lines = vim.split(result.stdout, "\n")
      if #lines > 0 and lines[#lines] == "" then
        table.remove(lines)
      end
      callback(lines, nil)
    end)
  end)
end

---Compute unified diff hunks for a single file against a base revision.
---@param base string base revision
---@param rel_path string head-side path relative to the repo root
---@param old_path string|nil pre-rename path, only set when the file was renamed
---@param worktree_cwd string worktree directory to run git from
---@param callback fun(hunks: GitTraceHunk[]|nil, err: string|nil)
function M.diff_hunks(base, rel_path, old_path, worktree_cwd, callback)
  local git = config.values.git_path
  local cmd = { git, "diff", "-U0", "-M", base, "--" }
  if old_path then
    table.insert(cmd, old_path)
  end
  table.insert(cmd, rel_path)

  vim.system(cmd, { text = true, cwd = worktree_cwd }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, vim.trim(result.stderr or "git diff failed"))
        return
      end
      callback(parser.parse_hunks(result.stdout), nil)
    end)
  end)
end

---Add a new worktree with a detached HEAD.
---@param path string worktree path
---@param ref string ref/sha to check out
---@param cwd string main repo directory to run git from
---@param callback fun(ok: boolean|nil, err: string|nil)
function M.worktree_add(path, ref, cwd, callback)
  local git = config.values.git_path

  vim.system({ git, "worktree", "add", "--detach", path, ref }, { text = true, cwd = cwd }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, vim.trim(result.stderr or "git worktree add failed"))
        return
      end
      callback(true, nil)
    end)
  end)
end

---Check out a ref with a detached HEAD inside an existing worktree.
---@param worktree_path string
---@param ref string
---@param callback fun(ok: boolean|nil, err: string|nil)
function M.worktree_checkout_detach(worktree_path, ref, callback)
  local git = config.values.git_path

  vim.system(
    { git, "checkout", "--detach", "--force", ref },
    { text = true, cwd = worktree_path },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback(nil, vim.trim(result.stderr or "git checkout failed"))
          return
        end
        callback(true, nil)
      end)
    end
  )
end

---List worktrees.
---@param cwd string directory to run git from
---@param callback fun(worktrees: table[]|nil, err: string|nil)
function M.worktree_list(cwd, callback)
  local git = config.values.git_path

  vim.system({ git, "worktree", "list", "--porcelain" }, { text = true, cwd = cwd }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, vim.trim(result.stderr or "git worktree list failed"))
        return
      end
      callback(parser.parse_worktree_list(result.stdout), nil)
    end)
  end)
end

---Remove a worktree.
---@param path string worktree path
---@param cwd string main repo directory to run git from
---@param callback fun(ok: boolean|nil, err: string|nil)
function M.worktree_remove(path, cwd, callback)
  local git = config.values.git_path

  vim.system({ git, "worktree", "remove", "--force", path }, { text = true, cwd = cwd }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, vim.trim(result.stderr or "git worktree remove failed"))
        return
      end
      callback(true, nil)
    end)
  end)
end

---Prune stale worktree administrative files.
---@param cwd string directory to run git from
---@param callback fun(ok: boolean|nil, err: string|nil)
function M.worktree_prune(cwd, callback)
  local git = config.values.git_path

  vim.system({ git, "worktree", "prune" }, { text = true, cwd = cwd }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, vim.trim(result.stderr or "git worktree prune failed"))
        return
      end
      callback(true, nil)
    end)
  end)
end

---Delete all git-trace review refs (refs/git-trace/*).
---@param cwd string directory to run git from
---@param callback fun(ok: boolean|nil, err: string|nil)
function M.delete_review_refs(cwd, callback)
  local git = config.values.git_path

  vim.system(
    { git, "for-each-ref", "--format=%(refname)", "refs/git-trace/" },
    { text = true, cwd = cwd },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback(nil, vim.trim(result.stderr or "git for-each-ref failed"))
          return
        end

        local refs = {}
        for line in result.stdout:gmatch("[^\n]+") do
          table.insert(refs, line)
        end

        if #refs == 0 then
          callback(true, nil)
          return
        end

        local function delete_next(i)
          if i > #refs then
            callback(true, nil)
            return
          end
          vim.system({ git, "update-ref", "-d", refs[i] }, { text = true, cwd = cwd }, function(del_result)
            vim.schedule(function()
              if del_result.code ~= 0 then
                callback(nil, vim.trim(del_result.stderr or "git update-ref failed"))
                return
              end
              delete_next(i + 1)
            end)
          end)
        end

        delete_next(1)
      end)
    end
  )
end

return M
