local config = require("git-trace.config")

local M = {}

local ZERO_HASH_PATTERN = "^0+$"

---Parse the first commit hash from git blame --porcelain output.
---@param output string
---@return string|nil hash
function M.parse_blame_porcelain(output)
  if not output or output == "" then
    return nil
  end
  local hash = output:match("^(%x+)")
  if not hash or hash:match(ZERO_HASH_PATTERN) then
    return nil
  end
  return hash
end

---Run git blame for a single line asynchronously.
---@param file string absolute file path
---@param line integer 1-based line number
---@param callback fun(hash: string|nil, err: string|nil)
function M.blame_line(file, line, callback)
  local git = config.values.git_path
  local line_range = ("%d,%d"):format(line, line)
  local cwd = vim.fn.fnamemodify(file, ":h")

  vim.system(
    { git, "blame", "-L", line_range, "--porcelain", "--", file },
    { text = true, cwd = cwd },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback(nil, vim.trim(result.stderr or "git blame failed"))
          return
        end
        local hash = M.parse_blame_porcelain(result.stdout)
        callback(hash, nil)
      end)
    end
  )
end

---Get the repository root directory.
---@param cwd string directory to run git from
---@param callback fun(root: string|nil, err: string|nil)
function M.repo_root(cwd, callback)
  local git = config.values.git_path
  vim.system(
    { git, "rev-parse", "--show-toplevel" },
    { text = true, cwd = cwd },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback(nil, vim.trim(result.stderr or "Not a git repository"))
          return
        end
        callback(vim.trim(result.stdout), nil)
      end)
    end
  )
end

---Get the current HEAD commit hash.
---@param cwd string directory to run git from
---@param callback fun(hash: string|nil, err: string|nil)
function M.head_hash(cwd, callback)
  local git = config.values.git_path
  vim.system(
    { git, "rev-parse", "HEAD" },
    { text = true, cwd = cwd },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback(nil, vim.trim(result.stderr or "git rev-parse failed"))
          return
        end
        callback(vim.trim(result.stdout), nil)
      end)
    end
  )
end

---Get the remote URL for origin.
---@param cwd string directory to run git from
---@param callback fun(url: string|nil, err: string|nil)
function M.remote_url(cwd, callback)
  local git = config.values.git_path
  vim.system(
    { git, "remote", "get-url", "origin" },
    { text = true, cwd = cwd },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback(nil, vim.trim(result.stderr or "Failed to get remote URL"))
          return
        end
        callback(vim.trim(result.stdout), nil)
      end)
    end
  )
end

return M
