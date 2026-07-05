local config = require("git-trace.config")
local github = require("git-trace.provider.github")
local review_git = require("git-trace.review.git")

local M = {}

---Build a filesystem-safe identifier for a repository that stays unique per clone.
---A short hash of the repo root is always appended so that multiple clones of the
---same repository never share a worktree directory.
---@param remote_url string|nil origin remote URL
---@param repo_root string absolute path to the repository root
---@return string
function M.repo_id(remote_url, repo_root)
  local owner_repo = github.parse_owner_repo(remote_url)
  local base
  if owner_repo then
    base = (owner_repo:gsub("/", "__"))
  else
    base = (vim.fn.fnamemodify(repo_root, ":t"):gsub("[^%w%.%-_]", "_"))
  end
  return base .. "-" .. vim.fn.sha256(repo_root):sub(1, 8)
end

---Compute the on-disk worktree path for a PR.
---@param base_dir string worktree base directory
---@param repo_id string identifier from M.repo_id
---@param pr_number integer PR number
---@return string
function M.worktree_path(base_dir, repo_id, pr_number)
  return base_dir .. "/" .. repo_id .. "/pr-" .. pr_number
end

---Resolve the base directory that holds all git-trace worktrees.
---@return string
function M.resolve_base_dir()
  local dir = config.values.review.worktree_dir
  if type(dir) == "string" then
    return dir
  end
  return vim.fn.stdpath("cache") .. "/git-trace/worktrees"
end

---Ensure a worktree checked out at the PR head exists, creating or refreshing it.
---@param repo_root string absolute path to the main repository
---@param remote_url string|nil origin remote URL
---@param pr_number integer PR number
---@param base_ref string base branch name
---@param callback fun(worktree_path: string|nil, err: string|nil)
function M.ensure(repo_root, remote_url, pr_number, base_ref, callback)
  local base_dir = M.resolve_base_dir()
  local path = M.worktree_path(base_dir, M.repo_id(remote_url, repo_root), pr_number)
  local ref = review_git.pr_ref(pr_number)

  local function refresh_existing()
    review_git.worktree_checkout_detach(path, ref, function(_, err)
      if err then
        callback(nil, err)
        return
      end
      callback(path, nil)
    end)
  end

  local function add_fresh()
    review_git.worktree_prune(repo_root, function(_, prune_err)
      if prune_err then
        callback(nil, prune_err)
        return
      end

      vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

      review_git.worktree_add(path, ref, repo_root, function(_, add_err)
        if not add_err then
          callback(path, nil)
          return
        end

        -- Recover from a leftover directory (e.g. a manually deleted cache) by
        -- removing it and retrying the add exactly once.
        if vim.fn.isdirectory(path) ~= 1 then
          callback(nil, add_err)
          return
        end

        vim.fn.delete(path, "rf")
        review_git.worktree_add(path, ref, repo_root, function(_, retry_err)
          if retry_err then
            callback(nil, retry_err)
            return
          end
          callback(path, nil)
        end)
      end)
    end)
  end

  review_git.fetch_pr(pr_number, base_ref, repo_root, function(_, fetch_err)
    if fetch_err then
      callback(nil, fetch_err)
      return
    end

    review_git.worktree_list(repo_root, function(worktrees, list_err)
      if list_err then
        callback(nil, list_err)
        return
      end

      for _, wt in ipairs(worktrees or {}) do
        if wt.path == path then
          refresh_existing()
          return
        end
      end

      add_fresh()
    end)
  end)
end

---Remove every git-trace worktree under the base directory, then prune and drop refs.
---@param repo_root string absolute path to the main repository
---@param callback fun(removed_count: integer|nil, err: string|nil)
function M.clean(repo_root, callback)
  local base_prefix = M.resolve_base_dir() .. "/"

  local function finalize(removed)
    review_git.worktree_prune(repo_root, function(_, prune_err)
      if prune_err then
        callback(nil, prune_err)
        return
      end
      review_git.delete_review_refs(repo_root, function(_, del_err)
        if del_err then
          callback(nil, del_err)
          return
        end
        callback(removed, nil)
      end)
    end)
  end

  review_git.worktree_list(repo_root, function(worktrees, list_err)
    if list_err then
      callback(nil, list_err)
      return
    end

    local targets = {}
    for _, wt in ipairs(worktrees or {}) do
      if vim.startswith(wt.path, base_prefix) then
        table.insert(targets, wt.path)
      end
    end

    local function remove_next(i, removed)
      if i > #targets then
        finalize(removed)
        return
      end
      review_git.worktree_remove(targets[i], repo_root, function(_, rm_err)
        if rm_err then
          callback(nil, rm_err)
          return
        end
        remove_next(i + 1, removed + 1)
      end)
    end

    remove_next(1, 0)
  end)
end

return M
