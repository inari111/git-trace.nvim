local git = require("git-trace.git")
local github = require("git-trace.provider.github")
local review_git = require("git-trace.review.git")
local worktree = require("git-trace.review.worktree")
local qflist = require("git-trace.review.ui.qflist")

---@class GitTraceReviewSession
---@field pr table            -- pr_view result
---@field repo_root string
---@field worktree string
---@field merge_base string
---@field files GitTraceReviewFile[]
---@field files_by_path table<string, GitTraceReviewFile>  -- key: absolute worktree path
---@field diff_enabled boolean -- used by a later task; starts true
---@field augroup integer      -- nvim_create_augroup("GitTraceReview", {clear=true})

local M = {}

---@type GitTraceReviewSession|nil
M._session = nil

---@type boolean
M._opening = false

---Read the current review session (exposed for tests).
---@return GitTraceReviewSession|nil
function M._get_session()
  return M._session
end

---@param msg string
---@param level integer
local function notify(msg, level)
  vim.notify("[git-trace] " .. msg, level)
end

---Resolve the directory to run git from, mirroring the browse commands.
---@return string
local function current_start_dir()
  local buf_name = vim.api.nvim_buf_get_name(0)
  if buf_name ~= "" then
    return vim.fn.fnamemodify(buf_name, ":h")
  end
  return vim.fn.getcwd()
end

---Open a PR review session. Passing nil prompts to select from the open PRs.
---@param number integer|nil PR number
function M.open(number)
  if M._opening then
    notify("A review is already being opened", vim.log.levels.WARN)
    return
  end
  M._opening = true

  if M._session then
    M.close()
  end

  local ctx = { number = number }

  local function done()
    M._opening = false
  end

  local function fail(err)
    notify(err, vim.log.levels.ERROR)
    done()
  end

  local function build_session(files)
    local files_by_path = {}
    for _, f in ipairs(files) do
      files_by_path[ctx.worktree .. "/" .. f.path] = f
    end

    M._session = {
      pr = ctx.pr,
      repo_root = ctx.root,
      worktree = ctx.worktree,
      merge_base = ctx.merge_base,
      files = files,
      files_by_path = files_by_path,
      diff_enabled = true,
      augroup = vim.api.nvim_create_augroup("GitTraceReview", { clear = true }),
    }

    qflist.set(ctx.pr, files, ctx.worktree)
    notify(("PR #%d: %d files"):format(ctx.pr.number, #files), vim.log.levels.INFO)
    done()
  end

  local function fetch_changed_files()
    review_git.changed_files(ctx.merge_base, review_git.pr_ref(ctx.pr.number), ctx.root, function(files, err)
      if err or not files then
        fail(err or "Failed to list changed files")
        return
      end
      if #files == 0 then
        notify(("PR #%d has no changed files"):format(ctx.pr.number), vim.log.levels.INFO)
        done()
        return
      end
      build_session(files)
    end)
  end

  local function compute_merge_base()
    local base_remote_ref = "refs/remotes/origin/" .. ctx.pr.base_ref
    review_git.merge_base(review_git.pr_ref(ctx.pr.number), base_remote_ref, ctx.root, function(base, err)
      if err or not base then
        fail(err or "Failed to compute merge base")
        return
      end
      ctx.merge_base = base
      fetch_changed_files()
    end)
  end

  local function ensure_worktree()
    worktree.ensure(ctx.root, ctx.remote_url, ctx.pr.number, ctx.pr.base_ref, function(wt_path, err)
      if err or not wt_path then
        fail(err or "Failed to prepare the worktree")
        return
      end
      ctx.worktree = wt_path
      compute_merge_base()
    end)
  end

  local function fetch_pr_view(num)
    github.pr_view(num, ctx.root, function(pr, err)
      if err or not pr then
        fail(err or "Failed to fetch PR metadata")
        return
      end
      if pr.state ~= "OPEN" then
        notify(("PR #%d is %s"):format(pr.number, tostring(pr.state)), vim.log.levels.WARN)
      end
      ctx.pr = pr
      ensure_worktree()
    end)
  end

  local function select_pr()
    github.list_open_prs(ctx.root, function(prs, err)
      if err or not prs then
        fail(err or "Failed to list open PRs")
        return
      end
      if #prs == 0 then
        notify("No open PRs found", vim.log.levels.INFO)
        done()
        return
      end
      vim.ui.select(prs, {
        prompt = "Select a PR to review:",
        format_item = function(pr)
          return ("#%d %s (%s)"):format(pr.number, pr.title, pr.author.login)
        end,
      }, function(selected)
        if not selected then
          done()
          return
        end
        fetch_pr_view(selected.number)
      end)
    end)
  end

  local start_dir = current_start_dir()
  git.repo_root(start_dir, function(root, root_err)
    if root_err or not root then
      fail(root_err or "Not a git repository")
      return
    end
    ctx.root = root

    git.remote_url(start_dir, function(remote_url, remote_err)
      if remote_err or not remote_url then
        fail(remote_err or "No remote found")
        return
      end
      ctx.remote_url = remote_url

      if ctx.number == nil then
        select_pr()
      else
        fetch_pr_view(ctx.number)
      end
    end)
  end)
end

---Close the current review session. Idempotent; leaves the worktree in place.
function M.close()
  if not M._session then
    return
  end

  pcall(vim.api.nvim_del_augroup_by_id, M._session.augroup)
  qflist.clear()
  M._session = nil
end

---Remove every git-trace review worktree after confirmation.
function M.clean()
  if vim.fn.confirm("Remove all git-trace review worktrees?", "&Yes\n&No", 2) ~= 1 then
    return
  end

  if M._session then
    M.close()
  end

  git.repo_root(current_start_dir(), function(root, root_err)
    if root_err or not root then
      notify(root_err or "Not a git repository", vim.log.levels.ERROR)
      return
    end
    worktree.clean(root, function(count, err)
      if err then
        notify(err, vim.log.levels.ERROR)
        return
      end
      notify(("Removed %d review worktree(s)"):format(count), vim.log.levels.INFO)
    end)
  end)
end

return M
