local git = require("git-trace.git")
local github = require("git-trace.provider.github")
local review_git = require("git-trace.review.git")
local worktree = require("git-trace.review.worktree")
local qflist = require("git-trace.review.ui.qflist")
local ui_diff = require("git-trace.review.ui.diff")
local review_signs = require("git-trace.review.ui.signs")

---@class GitTraceReviewSession
---@field pr table            -- pr_view result
---@field repo_root string
---@field worktree string
---@field merge_base string
---@field files GitTraceReviewFile[]
---@field files_by_path table<string, GitTraceReviewFile>  -- key: absolute worktree path
---@field diff_enabled boolean -- toggled between diff and single-file view; starts true
---@field augroup integer      -- nvim_create_augroup("GitTraceReview", {clear=true})
---@field base_cache table<string, string[]>|nil  -- cached base revision content, keyed by path
---@field hunk_cache table<string, GitTraceHunk[]>|nil -- cached diff hunks, keyed by path
---@field saved_winopts table<integer, table>|nil -- diff-sensitive winopts, keyed by window handle
---@field base_win integer|nil -- window handle of the base (left) side of the active diff
---@field base_buf integer|nil -- scratch buffer handle of the base side
---@field main_win integer|nil -- window handle of the worktree file (right) side

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

    local session = {
      pr = ctx.pr,
      repo_root = ctx.root,
      worktree = ctx.worktree,
      merge_base = ctx.merge_base,
      files = files,
      files_by_path = files_by_path,
      diff_enabled = true,
      augroup = vim.api.nvim_create_augroup("GitTraceReview", { clear = true }),
    }
    M._session = session

    -- Drive the native diff whenever one of the PR's files is displayed.
    -- Scratch (gittrace://) and unrelated buffers fall through the lookup.
    vim.api.nvim_create_autocmd("BufWinEnter", {
      group = session.augroup,
      callback = function(args)
        if M._session ~= session then
          return
        end
        local file = session.files_by_path[vim.api.nvim_buf_get_name(args.buf)]
        if not file then
          return
        end
        ui_diff.attach(session, file, vim.api.nvim_get_current_win())
      end,
    })

    -- Re-fetch and redraw change signs after an external edit (e.g. `:e`)
    -- reloads a reviewed file; diff view has no signs to refresh.
    vim.api.nvim_create_autocmd("BufReadPost", {
      group = session.augroup,
      callback = function(args)
        if M._session ~= session then
          return
        end
        local file = session.files_by_path[vim.api.nvim_buf_get_name(args.buf)]
        if not file then
          return
        end
        ui_diff.refresh_signs(session, file, args.buf)
      end,
    })

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
          -- GitHub returns a null author for deleted accounts, which decodes to
          -- vim.NIL; guard so format_item never throws and leaks M._opening.
          local author = "?"
          if type(pr.author) == "table" and type(pr.author.login) == "string" then
            author = pr.author.login
          end
          return ("#%d %s (%s)"):format(pr.number, pr.title, author)
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

  -- Defense in depth: any synchronous throw before the first async hop would
  -- otherwise leave M._opening stuck true. (Async callback errors still report
  -- through their own fail() handlers.)
  local ok, err = pcall(function()
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
  end)
  if not ok then
    fail("Unexpected error while opening review: " .. tostring(err))
  end
end

---Close the current review session. Idempotent; leaves the worktree in place.
function M.close()
  if not M._session then
    return
  end

  ui_diff.teardown(M._session)
  pcall(vim.api.nvim_del_augroup_by_id, M._session.augroup)
  qflist.clear()
  M._session = nil
end

---Toggle the current review between diff and single-file view.
function M.toggle_diff()
  if not M._session then
    notify("No active review session", vim.log.levels.WARN)
    return
  end
  ui_diff.toggle(M._session)
end

---Resolve the window/file to jump hunks in for `next_hunk`/`prev_hunk`, or nil
---(after a WARN notify) when there is no active session, the current buffer
---isn't one of its files, or the session is showing a native diff (where the
---built-in `]c` / `[c` already jump hunks).
---@return integer|nil win
---@return GitTraceReviewFile|nil file
local function hunk_jump_target()
  if not M._session then
    notify("No active review session", vim.log.levels.WARN)
    return nil, nil
  end

  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local file = M._session.files_by_path[vim.api.nvim_buf_get_name(buf)]
  if not file then
    notify("Current buffer is not part of the active review", vim.log.levels.WARN)
    return nil, nil
  end
  if M._session.diff_enabled then
    notify("Use ]c / [c to jump hunks in diff view", vim.log.levels.WARN)
    return nil, nil
  end

  return win, file
end

---Jump the cursor to a hunk in the current single-file review buffer.
---@param jump fun(win: integer, hunks: GitTraceHunk[]) signs.next_hunk or signs.prev_hunk
local function jump_hunk(jump)
  local win, file = hunk_jump_target()
  if not win then
    return
  end

  local session = M._session
  local expected_buf = vim.api.nvim_win_get_buf(win)
  ui_diff.with_hunks(session, file, function(hunks)
    -- The window may have moved on to a different buffer before this
    -- (possibly async, on a cache miss) fetch resolved.
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= expected_buf then
      return
    end
    jump(win, hunks)
  end)
end

---Move the cursor to the next changed hunk in the current single-file review buffer.
function M.next_hunk()
  jump_hunk(review_signs.next_hunk)
end

---Move the cursor to the previous changed hunk in the current single-file review buffer.
function M.prev_hunk()
  jump_hunk(review_signs.prev_hunk)
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
