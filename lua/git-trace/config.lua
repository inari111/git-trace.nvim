local M = {}

---@class GitTraceReviewKeymaps
---@field toggle_diff string
---@field next_file string
---@field prev_file string
---@field next_hunk string
---@field prev_hunk string
---@field close string

---@class GitTraceReviewConfig
---@field worktree_dir string|nil nil resolves to stdpath("cache").."/git-trace/worktrees" at runtime
---@field pr_list_limit integer
---@field open_qf boolean
---@field keymaps GitTraceReviewKeymaps|false false disables all review keymaps

---@class GitTraceConfig
---@field pr_state string
---@field gh_path string
---@field git_path string
---@field review GitTraceReviewConfig
local defaults = {
  pr_state = "merged",
  gh_path = "gh",
  git_path = "git",
  review = {
    worktree_dir = nil,
    pr_list_limit = 30,
    open_qf = true,
    keymaps = {
      toggle_diff = "<leader>rd",
      next_file = "]f",
      prev_file = "[f",
      next_hunk = "]c",
      prev_hunk = "[c",
      close = "<leader>rq",
    },
  },
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

  if type(c.review) ~= "table" then
    vim.notify(
      "[git-trace] Invalid review config. Must be a table",
      vim.log.levels.ERROR
    )
    c.review = vim.deepcopy(defaults.review)
  end

  local review = c.review
  local limit = review.pr_list_limit
  if type(limit) ~= "number" or limit <= 0 or limit ~= math.floor(limit) then
    vim.notify(
      ('[git-trace] Invalid review.pr_list_limit "%s". Must be a positive integer'):format(tostring(limit)),
      vim.log.levels.ERROR
    )
    review.pr_list_limit = defaults.review.pr_list_limit
  end

  if review.worktree_dir ~= nil and type(review.worktree_dir) ~= "string" then
    vim.notify(
      "[git-trace] Invalid review.worktree_dir. Must be a string or nil",
      vim.log.levels.ERROR
    )
    review.worktree_dir = defaults.review.worktree_dir
  end

  if review.keymaps ~= false and type(review.keymaps) ~= "table" then
    vim.notify(
      "[git-trace] Invalid review.keymaps. Must be a table or false",
      vim.log.levels.ERROR
    )
    review.keymaps = vim.deepcopy(defaults.review.keymaps)
  end
end

return M
