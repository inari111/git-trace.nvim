local M = {}

---@class GitTraceConfig
---@field pr_state string
---@field gh_path string
---@field git_path string
local defaults = {
  pr_state = "merged",
  gh_path = "gh",
  git_path = "git",
}

---@type GitTraceConfig
M.values = vim.deepcopy(defaults)

local valid_pr_states = { merged = true, all = true, open = true }

---@param opts? table
---@return GitTraceConfig
function M.apply(opts)
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  M.validate()
  return M.values
end

function M.validate()
  local c = M.values
  if not valid_pr_states[c.pr_state] then
    vim.notify(
      ('[git-trace] Invalid pr_state "%s". Must be one of: merged, all, open'):format(c.pr_state),
      vim.log.levels.ERROR
    )
    c.pr_state = defaults.pr_state
  end

  if vim.fn.executable(c.gh_path) == 0 then
    vim.notify(
      "[git-trace] gh CLI not found. Install: https://cli.github.com",
      vim.log.levels.WARN
    )
  end

  if vim.fn.executable(c.git_path) == 0 then
    vim.notify(
      "[git-trace] git not found. Please install git.",
      vim.log.levels.WARN
    )
  end
end

return M
