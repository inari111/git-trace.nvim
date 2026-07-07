local review_git = require("git-trace.review.git")
local review_signs = require("git-trace.review.ui.signs")
local config = require("git-trace.config")

local M = {}

---Window-local options that :diffthis clobbers and :diffoff resets to Vim
---defaults rather than the user's values, so we save and restore them ourselves.
local SAVED_WINOPTS = { "wrap", "foldmethod", "foldcolumn", "foldenable", "scrollbind", "cursorbind" }

---@param msg string
---@param level integer
local function notify(msg, level)
  vim.notify("[git-trace] " .. msg, level)
end

---Attach the configured review keymaps to a review buffer, buffer-local and
---idempotent. No-op when `review.keymaps` is `false`; each key is skipped
---individually when it is not a string (nil/false disables just that one). The
---review module is required lazily to avoid a load-time require cycle
---(review/init.lua requires this module).
---@param buf integer buffer handle
local function set_keymaps(buf)
  local keymaps = config.values.review.keymaps
  if keymaps == false then
    return
  end
  if vim.b[buf].git_trace_keymaps_set then
    return
  end

  local review = require("git-trace.review")
  local actions = {
    { key = "toggle_diff", fn = review.toggle_diff, desc = "git-trace: toggle diff view" },
    { key = "next_file", fn = review.next_file, desc = "git-trace: next file" },
    { key = "prev_file", fn = review.prev_file, desc = "git-trace: previous file" },
    { key = "next_hunk", fn = review.next_hunk, desc = "git-trace: next hunk" },
    { key = "prev_hunk", fn = review.prev_hunk, desc = "git-trace: previous hunk" },
    { key = "close", fn = review.close, desc = "git-trace: close review" },
  }

  for _, action in ipairs(actions) do
    local lhs = keymaps[action.key]
    if type(lhs) == "string" then
      vim.keymap.set("n", lhs, action.fn, { buffer = buf, silent = true, desc = action.desc })
    end
  end

  vim.b[buf].git_trace_keymaps_set = true
end

---True if the current quickfix list belongs to a git-trace review (carries the
---`git_trace_review` context marker set by review/ui/qflist.lua). Guards against
---closing a quickfix window the user opened for something else.
---@return boolean
local function qf_is_mine()
  local qf = vim.fn.getqflist({ context = 0 })
  return type(qf.context) == "table" and qf.context.git_trace_review ~= nil
end

---Close the current tabpage's quickfix window, if one is open and it belongs
---to this review. Called before building a file's layout so the window being
---attached (and the diff split built from it) gets the full screen height
---instead of being squeezed above the quickfix window. File navigation keeps
---working afterwards via ]f/[f (:cnext/:cprev), which do not need the
---quickfix window visible; :copen brings the list back at any time.
local function close_qf_window()
  if not config.values.review.close_qf_on_open then
    return
  end
  if not qf_is_mine() then
    return
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "quickfix" then
      pcall(vim.cmd.cclose)
      return
    end
  end
end

---Filetypes used by popular dashboard/greeter plugins. Quickfix cannot reuse
---their special (buftype=nofile) windows and opens the review file in a small
---split beside them instead, squeezing the diff.
local DASHBOARD_FILETYPES = {
  snacks_dashboard = true, -- snacks.nvim (LazyVim default)
  dashboard = true, -- dashboard-nvim
  alpha = true, -- alpha-nvim
  ministarter = true, -- mini.starter
  starter = true, -- mini.starter (old)
  startify = true, -- vim-startify
}

---Close every dashboard window in the current tabpage except keep_win, so the
---window the review file landed in expands to full size before the diff layout
---is built on it. Dashboards self-close when a file opens in them; this covers
---the case where quickfix opened the file in a split beside one instead.
---@param keep_win integer window handle that must stay open
local function close_dashboard_windows(keep_win)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= keep_win and vim.api.nvim_win_is_valid(w) then
      local buf = vim.api.nvim_win_get_buf(w)
      if vim.bo[buf].buftype == "nofile" and DASHBOARD_FILETYPES[vim.bo[buf].filetype] then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end
end

---Absolute worktree path of a file (the quickfix filename / files_by_path key).
---@param session GitTraceReviewSession
---@param file GitTraceReviewFile
---@return string
local function abs_path(session, file)
  return session.worktree .. "/" .. file.path
end

---Save the diff-sensitive window options of a window before enabling diff mode.
---@param session GitTraceReviewSession
---@param win integer window handle
local function save_winopts(session, win)
  session.saved_winopts = session.saved_winopts or {}
  local opts = {}
  for _, name in ipairs(SAVED_WINOPTS) do
    opts[name] = vim.wo[win][name]
  end
  session.saved_winopts[win] = opts
end

---Restore the window options previously saved by save_winopts.
---@param session GitTraceReviewSession
---@param win integer window handle
local function restore_winopts(session, win)
  if not session.saved_winopts then
    return
  end
  local opts = session.saved_winopts[win]
  if not opts then
    return
  end
  for _, name in ipairs(SAVED_WINOPTS) do
    vim.wo[win][name] = opts[name]
  end
  session.saved_winopts[win] = nil
end

---Tear down the active diff layout: close the base window, turn diff off on the
---main window and restore its saved options. Clears the recorded handles.
---@param session GitTraceReviewSession
local function close_diff(session)
  -- Invalidate any base-fetch callback still in flight (see M.show_diff) so it
  -- cannot rebuild the diff layout after we have just torn it down.
  session.diff_request_id = (session.diff_request_id or 0) + 1

  if session.base_win and vim.api.nvim_win_is_valid(session.base_win) then
    pcall(vim.api.nvim_win_close, session.base_win, true)
  end
  if session.main_win and vim.api.nvim_win_is_valid(session.main_win) then
    pcall(vim.api.nvim_win_call, session.main_win, function()
      vim.cmd.diffoff()
    end)
    restore_winopts(session, session.main_win)
  end
  session.base_win = nil
  session.base_buf = nil
  session.main_win = nil
end

---Create the read-only base-side scratch buffer for a file.
---@param session GitTraceReviewSession
---@param file GitTraceReviewFile
---@param ref_buf integer buffer to inherit the filetype from
---@param lines string[] base revision content
---@return integer base_buf
local function create_base_buf(session, file, ref_buf, lines)
  local base_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(base_buf, 0, -1, false, lines)
  vim.bo[base_buf].buftype = "nofile"
  vim.bo[base_buf].bufhidden = "wipe"
  vim.bo[base_buf].swapfile = false

  local ft = vim.bo[ref_buf].filetype
  if ft == nil or ft == "" then
    ft = vim.filetype.match({ filename = file.path })
  end
  if ft and ft ~= "" then
    vim.bo[base_buf].filetype = ft
  end

  local rel = file.old_path or file.path
  local name = ("gittrace://pr%d/%s/%s"):format(session.pr.number, session.merge_base:sub(1, 8), rel)
  -- pcall guards E95 if a same-named scratch buffer has not been wiped yet.
  pcall(vim.api.nvim_buf_set_name, base_buf, name)

  vim.bo[base_buf].modifiable = false
  set_keymaps(base_buf)
  return base_buf
end

---True while `win` is still valid and still displays the file it was opened for.
---Guards against the user navigating away before an async base fetch resolves.
---@param win integer window handle
---@param expected_path string
---@return boolean
local function win_still_shows(win, expected_path)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == expected_path
end

---Fetch the base revision content of a file, using the session cache.
---Added files (status "A") have no base side, so an empty list is returned
---without invoking git. Errors are reported and swallowed (callback not called).
---@param session GitTraceReviewSession
---@param file GitTraceReviewFile
---@param on_lines fun(lines: string[])
local function with_base_lines(session, file, on_lines)
  session.base_cache = session.base_cache or {}

  if file.status == "A" then
    on_lines({})
    return
  end
  if session.base_cache[file.path] then
    on_lines(session.base_cache[file.path])
    return
  end

  review_git.show_file(session.merge_base, file.old_path or file.path, session.repo_root, function(lines, err)
    if err or not lines then
      notify(err or ("Failed to load base content for " .. file.path), vim.log.levels.ERROR)
      return
    end
    session.base_cache[file.path] = lines
    on_lines(lines)
  end)
end

---Fetch the diff hunks of `file` against the merge base, using the session cache.
---Errors are reported and swallowed (callback not called).
---@param session GitTraceReviewSession
---@param file GitTraceReviewFile
---@param on_hunks fun(hunks: GitTraceHunk[])
function M.with_hunks(session, file, on_hunks)
  session.hunk_cache = session.hunk_cache or {}

  if session.hunk_cache[file.path] then
    on_hunks(session.hunk_cache[file.path])
    return
  end

  review_git.diff_hunks(session.merge_base, file.path, file.old_path, session.worktree, function(hunks, err)
    if err or not hunks then
      notify(err or ("Failed to load diff hunks for " .. file.path), vim.log.levels.ERROR)
      return
    end
    session.hunk_cache[file.path] = hunks
    on_hunks(hunks)
  end)
end

---Fetch and apply the change signs of `file` to `win`'s buffer. No-op for binary
---or deleted files, which have no meaningful single-file diff to mark. Guards
---against the window having moved on to a different file before the async
---hunk fetch resolves.
---@param session GitTraceReviewSession
---@param file GitTraceReviewFile
---@param win integer window handle
local function apply_signs(session, file, win)
  if file.binary or file.status == "D" then
    return
  end

  local expected = abs_path(session, file)
  M.with_hunks(session, file, function(hunks)
    if not win_still_shows(win, expected) then
      return
    end
    review_signs.apply(vim.api.nvim_win_get_buf(win), hunks)
  end)
end

---Show `file` as a native diff: a scratch base buffer on the left and the real
---worktree file on the right, both in diff mode, focus left on the worktree file.
---@param session GitTraceReviewSession
---@param file GitTraceReviewFile
---@param win integer window handle currently displaying the worktree file
function M.show_diff(session, file, win)
  local expected = abs_path(session, file)
  -- Stamp this request so a base fetch that resolves after the user has toggled
  -- back to single view (or the session was torn down) is dropped instead of
  -- rebuilding the diff. close_diff bumps the same counter.
  session.diff_request_id = (session.diff_request_id or 0) + 1
  local request_id = session.diff_request_id

  with_base_lines(session, file, function(lines)
    if request_id ~= session.diff_request_id or not session.diff_enabled then
      return
    end
    if not win_still_shows(win, expected) then
      return
    end

    local main_buf = vim.api.nvim_win_get_buf(win)
    -- Diff mode colors changes itself; single-view signs would duplicate that.
    review_signs.clear(main_buf)
    local base_buf = create_base_buf(session, file, main_buf, lines)

    -- Save the main window's diff-sensitive options before diffthis touches them.
    save_winopts(session, win)

    -- leftabove vsplit duplicates the worktree file into a new left window and
    -- focuses it; we then swap in the base buffer.
    vim.api.nvim_set_current_win(win)
    vim.cmd({ cmd = "vsplit", mods = { split = "aboveleft" } })
    local base_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(base_win, base_buf)

    vim.api.nvim_win_call(base_win, function()
      vim.cmd.diffthis()
    end)
    vim.api.nvim_win_call(win, function()
      vim.cmd.diffthis()
    end)

    -- Keep focus on the real worktree file so LSP and edits target it.
    vim.api.nvim_set_current_win(win)

    session.base_win = base_win
    session.base_buf = base_buf
    session.main_win = win
  end)
end

---Show `file` as a single (non-diff) view, tearing down any active diff layout
---and marking its changed regions with signs.
---@param session GitTraceReviewSession
---@param file GitTraceReviewFile
---@param win integer window handle
function M.show_single(session, file, win)
  close_diff(session)
  apply_signs(session, file, win)
end

---Re-fetch a file's hunks and redraw its signs, e.g. after an external edit
---(`:e`) reloaded the buffer and invalidated the cached hunks. No-op for
---binary/deleted files or while the session is showing a native diff (which
---has no signs to refresh).
---@param session GitTraceReviewSession
---@param file GitTraceReviewFile
---@param bufnr integer buffer handle
function M.refresh_signs(session, file, bufnr)
  if file.binary or file.status == "D" or session.diff_enabled then
    return
  end

  session.hunk_cache = session.hunk_cache or {}
  session.hunk_cache[file.path] = nil

  M.with_hunks(session, file, function(hunks)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    review_signs.apply(bufnr, hunks)
  end)
end

---Swap a placeholder empty buffer (deleted file) for a read-only base buffer,
---without building a diff.
---@param session GitTraceReviewSession
---@param file GitTraceReviewFile
---@param win integer window handle
local function show_deleted(session, file, win)
  local expected = abs_path(session, file)

  with_base_lines(session, file, function(lines)
    if not win_still_shows(win, expected) then
      return
    end
    local placeholder = vim.api.nvim_win_get_buf(win)
    local base_buf = create_base_buf(session, file, placeholder, lines)
    -- Marks the buffer as a deleted-file view so toggle can refuse it: the
    -- scratch buffer's gittrace:// name never matches files_by_path.
    vim.b[base_buf].git_trace_deleted = file.path
    vim.api.nvim_win_set_buf(win, base_buf)
    pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
    notify(("%s was deleted in this PR"):format(file.path), vim.log.levels.INFO)
  end)
end

---Entry point invoked from the BufWinEnter hook when a review file lands in a
---window. Sets up (or refreshes) the diff layout for the file.
---@param session GitTraceReviewSession
---@param file GitTraceReviewFile
---@param win integer window handle displaying the file
function M.attach(session, file, win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  local expected = abs_path(session, file)
  -- Re-entry guard: this window already set this file up.
  if vim.w[win].git_trace_attached == expected then
    return
  end

  -- Close the git-trace quickfix window (if open) before anything else, so
  -- `win` expands to full height before the diff/single layout is built on it.
  close_qf_window()

  -- A dashboard window (snacks/alpha/…) cannot be reused by quickfix, which
  -- opens the file in a small split beside it instead. Close it so the diff
  -- fills the screen.
  close_dashboard_windows(win)

  -- A previous file's base window may linger when quickfix reuses this window
  -- (:cnext). Tear it down before setting up the new file.
  close_diff(session)
  vim.w[win].git_trace_attached = nil

  -- Wire keymaps onto the worktree file buffer for every kind except deleted
  -- files, whose placeholder is wiped and replaced by a base scratch that gets
  -- its keymaps from create_base_buf.
  if file.status ~= "D" then
    set_keymaps(vim.api.nvim_win_get_buf(win))
  end

  if file.binary then
    notify("binary file: " .. file.path, vim.log.levels.INFO)
  elseif file.status == "D" then
    -- Quickfix creates a fresh placeholder buffer on every visit to a deleted
    -- entry, so leave no marker: the next visit must swap the base in again.
    show_deleted(session, file, win)
    return
  elseif session.diff_enabled then
    M.show_diff(session, file, win)
  else
    M.show_single(session, file, win)
  end

  vim.w[win].git_trace_attached = expected
end

---Toggle the whole session between diff and single-file view. The state is kept
---across files (a later :cnext opens the next file in the same mode). Binary and
---deleted files cannot be diffed, so toggling on them is a no-op with a warning.
---@param session GitTraceReviewSession
function M.toggle(session)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)

  -- When focus is on the base scratch window of an active diff, act on the
  -- worktree file in the main window instead. That scratch buffer's gittrace://
  -- name is not in files_by_path, so without this redirect we would treat it as
  -- "not part of the review" and refuse.
  if session.main_win and buf == session.base_buf and vim.api.nvim_win_is_valid(session.main_win) then
    win = session.main_win
    buf = vim.api.nvim_win_get_buf(win)
  end

  local file = session.files_by_path[vim.api.nvim_buf_get_name(buf)]

  -- Deleted files are shown through a base scratch buffer whose gittrace://
  -- name is not in files_by_path, hence the buffer-local marker check.
  if vim.b[buf].git_trace_deleted ~= nil or (file and (file.binary or file.status == "D")) then
    notify("diff view is not available for this file", vim.log.levels.WARN)
    return
  end

  -- The current buffer is not a review file (e.g. a stray split). Flipping
  -- diff_enabled here would desync the session state from the on-screen layout,
  -- so refuse without touching it.
  if not file then
    notify("current buffer is not part of the active review", vim.log.levels.WARN)
    return
  end

  session.diff_enabled = not session.diff_enabled

  if session.diff_enabled then
    M.show_diff(session, file, win)
  else
    M.show_single(session, file, win)
  end
end

---Remove any diff layout owned by the session. The session-wide cleanup
---(augroup, quickfix) belongs to review/init.lua.
---@param session GitTraceReviewSession
function M.teardown(session)
  local main_win = session.main_win
  close_diff(session)
  if main_win and vim.api.nvim_win_is_valid(main_win) then
    pcall(function()
      vim.w[main_win].git_trace_attached = nil
    end)
  end
end

return M
