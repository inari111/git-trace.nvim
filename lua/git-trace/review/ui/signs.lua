local M = {}

local ns = vim.api.nvim_create_namespace("git-trace-review")

---@param msg string
---@param level integer
local function notify(msg, level)
  vim.notify("[git-trace] " .. msg, level)
end

---Link each mark kind's highlight group to a Diff* group. `default = true` lets
---users override these in their colorscheme/config without git-trace clobbering
---it. Re-applied on ColorScheme since switching a colorscheme (via `:hi clear`)
---can drop the links.
local function setup_highlights()
  vim.api.nvim_set_hl(0, "GitTraceReviewAdd", { link = "DiffAdd", default = true })
  vim.api.nvim_set_hl(0, "GitTraceReviewChange", { link = "DiffChange", default = true })
  vim.api.nvim_set_hl(0, "GitTraceReviewDelete", { link = "DiffDelete", default = true })
end

setup_highlights()

-- Restore the links after a colorscheme change wipes them. The augroup is
-- cleared on (re)load so the autocmd is registered exactly once.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("GitTraceReviewSigns", { clear = true }),
  desc = "Re-link git-trace review highlight groups after a colorscheme change",
  callback = setup_highlights,
})

local HL_GROUP = {
  add = "GitTraceReviewAdd",
  change = "GitTraceReviewChange",
  delete = "GitTraceReviewDelete",
}

local SIGN_TEXT = {
  add = "+",
  change = "~",
  delete = "_",
}

---1-based buffer line a hunk's sign(s) should be anchored to when jumping to it.
---Mirrors the delete clamp in `marks_for`: `git diff -U0` reports the new-side
---anchor of a pure deletion as the line before it, which is 0 at the top of the
---file, so it is clamped to line 1.
---@param hunk GitTraceHunk
---@return integer
local function anchor_line(hunk)
  if hunk.new_count == 0 then
    return math.max(hunk.new_start, 1)
  end
  return hunk.new_start
end

---Expand hunks (from `review.git.diff_hunks`) into per-line sign marks on the
---new (head) side. Pure function, no buffer access.
---@param hunks GitTraceHunk[]|nil
---@return { line: integer, kind: "add"|"change"|"delete" }[]
function M.marks_for(hunks)
  local marks = {}
  for _, hunk in ipairs(hunks or {}) do
    if hunk.old_count == 0 then
      for line = hunk.new_start, hunk.new_start + hunk.new_count - 1 do
        table.insert(marks, { line = line, kind = "add" })
      end
    elseif hunk.new_count == 0 then
      table.insert(marks, { line = anchor_line(hunk), kind = "delete" })
    else
      for line = hunk.new_start, hunk.new_start + hunk.new_count - 1 do
        table.insert(marks, { line = line, kind = "change" })
      end
    end
  end
  return marks
end

---Redraw the change signs of `bufnr` from `hunks`: clears any existing marks
---first, so re-applying never duplicates signs. Wrapped in pcall per mark since
---a hunk may point past the end of the buffer if it was edited concurrently.
---@param bufnr integer
---@param hunks GitTraceHunk[]|nil
function M.apply(bufnr, hunks)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  for _, mark in ipairs(M.marks_for(hunks)) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, mark.line - 1, 0, {
      sign_text = SIGN_TEXT[mark.kind],
      sign_hl_group = HL_GROUP[mark.kind],
      invalidate = true,
    })
  end
end

---Remove all change signs from `bufnr`. No-op on an invalid buffer.
---@param bufnr integer
function M.clear(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
end

---Sorted (ascending) anchor lines of `hunks`, per `anchor_line`.
---@param hunks GitTraceHunk[]
---@return integer[]
local function sorted_anchors(hunks)
  local anchors = {}
  for _, hunk in ipairs(hunks) do
    table.insert(anchors, anchor_line(hunk))
  end
  table.sort(anchors)
  return anchors
end

---Move `win`'s cursor to the first hunk anchor strictly after (`forward`) or
---before (not `forward`) the current line, wrapping around when the cursor is
---already past the last (or before the first) hunk. Notifies and does nothing
---when `hunks` is empty.
---@param win integer window handle
---@param hunks GitTraceHunk[]|nil
---@param forward boolean
local function jump(win, hunks, forward)
  if not hunks or #hunks == 0 then
    notify("no hunks", vim.log.levels.INFO)
    return
  end

  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  if not ok then
    return
  end
  local cur_line = cursor[1]
  local anchors = sorted_anchors(hunks)

  local target
  if forward then
    for _, line in ipairs(anchors) do
      if line > cur_line then
        target = line
        break
      end
    end
    target = target or anchors[1]
  else
    for i = #anchors, 1, -1 do
      if anchors[i] < cur_line then
        target = anchors[i]
        break
      end
    end
    target = target or anchors[#anchors]
  end

  pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
end

---Move the cursor to the next hunk after the current line, wrapping to the
---first hunk if already past the last one.
---@param win integer window handle
---@param hunks GitTraceHunk[]|nil
function M.next_hunk(win, hunks)
  jump(win, hunks, true)
end

---Move the cursor to the previous hunk before the current line, wrapping to
---the last hunk if already before the first one.
---@param win integer window handle
---@param hunks GitTraceHunk[]|nil
function M.prev_hunk(win, hunks)
  jump(win, hunks, false)
end

return M
