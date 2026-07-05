local config = require("git-trace.config")

local M = {}

---Format an addition/deletion count, using "-" for binary files.
---@param n integer|nil
---@return string
local function count_str(n)
  if n == nil then
    return "-"
  end
  return tostring(n)
end

---Build quickfix items from the changed files of a PR.
---Deleted files use the same worktree-relative filename as other entries; opening
---one yields an empty buffer until a later task swaps in the diff content.
---@param files GitTraceReviewFile[]
---@param worktree_path string absolute path to the PR worktree
---@return table[] quickfix items
function M.build_items(files, worktree_path)
  local items = {}
  for _, f in ipairs(files) do
    local display_path = f.path
    if f.old_path then
      display_path = f.old_path .. " -> " .. f.path
    end
    if f.binary then
      display_path = display_path .. " [binary]"
    end

    table.insert(items, {
      filename = worktree_path .. "/" .. f.path,
      lnum = 1,
      text = ("%s +%s -%s  %s"):format(f.status, count_str(f.additions), count_str(f.deletions), display_path),
    })
  end
  return items
end

---Populate the quickfix list with a PR's changed files.
---@param pr table pr_view result (needs number, title)
---@param files GitTraceReviewFile[]
---@param worktree_path string absolute path to the PR worktree
function M.set(pr, files, worktree_path)
  vim.fn.setqflist({}, " ", {
    title = ("GitTrace PR #%d: %s"):format(pr.number, pr.title),
    items = M.build_items(files, worktree_path),
    context = { git_trace_review = pr.number },
  })
  if config.values.review.open_qf then
    vim.cmd.copen()
  end
end

---Clear the quickfix list, but only when it belongs to a git-trace review.
function M.clear()
  local qf = vim.fn.getqflist({ context = 0 })
  if type(qf.context) == "table" and qf.context.git_trace_review ~= nil then
    vim.fn.setqflist({}, "r", { items = {}, title = "" })
  end
end

return M
