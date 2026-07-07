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

  -- Close any previous session (wiping its worktree buffers) before marking the
  -- open in-flight, so close() is not itself refused by the in-flight guard.
  if M._session then
    M.close()
  end

  M._opening = true

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
    -- nested: attach closes windows (quickfix, dashboard) and swaps buffers;
    -- the events those actions trigger (BufWipeout etc.) must reach other
    -- plugins' autocmds — snacks.nvim, for one, tears down its dashboard
    -- state in a BufWipeout handler and errors on stale windows otherwise.
    vim.api.nvim_create_autocmd("BufWinEnter", {
      group = session.augroup,
      nested = true,
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

---Wipe every listed buffer that lives under `worktree_path`, so switching PRs
---(open() closes the previous session first) does not leave the previous
---worktree's file buffers -- and their buffer-local keymaps that still call into
---the live review -- accumulating in the buffer list. Guarded per buffer since a
---buffer may be unloadable (e.g. modified without `bufhidden=wipe`).
---@param worktree_path string absolute path to the session's worktree
local function wipe_worktree_buffers(worktree_path)
  local prefix = worktree_path .. "/"
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" and vim.startswith(name, prefix) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

---Close the current review session. Idempotent; leaves the worktree on disk for
---reuse but wipes its file buffers so switching PRs does not orphan them.
---Refuses (and warns) while an open is in-flight so a slow open is never
---silently discarded.
function M.close()
  if M._opening then
    notify("A review is being opened, please try again", vim.log.levels.WARN)
    return
  end
  if not M._session then
    return
  end

  local session = M._session
  ui_diff.teardown(session)
  pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
  qflist.clear()
  wipe_worktree_buffers(session.worktree)
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

---Jump to a changed hunk from the current review buffer. In single-file view
---this uses the change-sign anchors; in diff view it defers to the built-in
---`]c` / `[c` so the same key jumps hunks in either view. Warns and does nothing
---when there is no session or the current buffer isn't part of the review.
---@param diff_key "]c"|"[c" native diff jump to run in diff view
---@param sign_jump fun(win: integer, hunks: GitTraceHunk[]) signs.next_hunk or signs.prev_hunk
local function jump_hunk(diff_key, sign_jump)
  local session = M._session
  if not session then
    notify("No active review session", vim.log.levels.WARN)
    return
  end

  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local file = session.files_by_path[vim.api.nvim_buf_get_name(buf)]

  -- A deleted file is shown through a read-only base scratch (no worktree file
  -- in files_by_path, no diff, no signs) but is still part of the review, so it
  -- must not draw the "not part of the review" warning. There is nothing to
  -- navigate, so report that instead.
  if vim.b[buf].git_trace_deleted ~= nil then
    notify("No diff to navigate for this file", vim.log.levels.INFO)
    return
  end

  if session.diff_enabled then
    -- The built-in diff jump only makes sense on the diff's own windows (the
    -- worktree file or its base scratch); elsewhere warn like single view does.
    if not (file or buf == session.base_buf) then
      notify("Current buffer is not part of the active review", vim.log.levels.WARN)
      return
    end
    -- Binary files have no navigable diff; the built-in `]c`/`[c` would raise
    -- E99 (buffer not in diff mode), which pcall would swallow in silence.
    if file and file.binary then
      notify("No diff to navigate for this file", vim.log.levels.INFO)
      return
    end
    pcall(vim.cmd, "normal! " .. diff_key)
    return
  end

  if not file then
    notify("Current buffer is not part of the active review", vim.log.levels.WARN)
    return
  end

  local expected_buf = buf
  ui_diff.with_hunks(session, file, function(hunks)
    -- The window may have moved on to a different buffer before this
    -- (possibly async, on a cache miss) fetch resolved.
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= expected_buf then
      return
    end
    sign_jump(win, hunks)
  end)
end

---Move the cursor to the next changed hunk (single view) or next diff change
---(diff view) in the current review buffer.
function M.next_hunk()
  jump_hunk("]c", review_signs.next_hunk)
end

---Move the cursor to the previous changed hunk (single view) or previous diff
---change (diff view) in the current review buffer.
function M.prev_hunk()
  jump_hunk("[c", review_signs.prev_hunk)
end

---Move the quickfix cursor to the next/previous changed file. Focuses the
---session's main (right) window first when it is valid, so `:cnext` reuses it:
---running the raw quickfix jump from the base (left) diff window opens the file
---in the wrong window and breaks the layout.
---@param cmd fun() vim.cmd.cnext or vim.cmd.cprev
---@param edge string INFO message shown when already at the first/last file
local function jump_file(cmd, edge)
  if not M._session then
    notify("No active review session", vim.log.levels.WARN)
    return
  end

  local main_win = M._session.main_win

  -- Tear down the active diff BEFORE the quickfix jump. :cnext reuses the main
  -- window, and loading a file into a window that is still in diff mode drags
  -- the new buffer into a transient diff against the old base, which leaves its
  -- diff state corrupted: the whole buffer renders as changed (hiding syntax
  -- highlighting under the Diff* colors) and :diffupdate does not clear it. The
  -- next file's BufWinEnter -> attach rebuilds the diff cleanly on a plain
  -- window. Only needed in diff view; single view has no diff to corrupt.
  if M._session.diff_enabled then
    ui_diff.teardown(M._session)
  end

  if main_win and vim.api.nvim_win_is_valid(main_win) then
    vim.api.nvim_set_current_win(main_win)
  end

  if not pcall(cmd) then
    notify(edge, vim.log.levels.INFO)
  end
end

---Open the next changed file of the PR from the quickfix list.
function M.next_file()
  jump_file(vim.cmd.cnext, "last file")
end

---Open the previous changed file of the PR from the quickfix list.
function M.prev_file()
  jump_file(vim.cmd.cprev, "first file")
end

---Remove every git-trace review worktree after confirmation.
function M.clean()
  -- Refuse while an open is in-flight: its session is not built yet, so cleaning
  -- would remove the very worktree/refs the open is fetching into.
  if M._opening then
    notify("A review is being opened, please try again", vim.log.levels.WARN)
    return
  end

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
