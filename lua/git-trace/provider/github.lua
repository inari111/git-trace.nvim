local config = require("git-trace.config")

local M = {}

---Translate gh CLI stderr into a friendlier auth message when applicable.
---@param stderr string|nil
---@return string
local function translate_gh_error(stderr)
  stderr = stderr or ""
  if stderr:match("auth") or stderr:match("login") then
    return "gh auth login required. Run: gh auth login"
  end
  return stderr
end

---Parse JSON output from `gh pr list --json number,url`.
---@param json_str string
---@return table[]|nil list of {number: integer, url: string}
function M.parse_pr_list(json_str)
  if not json_str or json_str == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, json_str)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

---Build a GitHub file URL with optional line range.
---@param remote_url string e.g. "git@github.com:user/repo.git" or "https://github.com/user/repo.git"
---@param hash string commit hash
---@param rel_path string file path relative to repo root
---@param start_line integer|nil
---@param end_line integer|nil
---@return string|nil url
function M.build_file_url(remote_url, hash, rel_path, start_line, end_line)
  local owner_repo = M.parse_owner_repo(remote_url)
  if not owner_repo then
    return nil
  end

  local url = ("https://github.com/%s/blob/%s/%s"):format(owner_repo, hash, rel_path)

  if start_line then
    url = url .. "#L" .. start_line
    if end_line and end_line ~= start_line then
      url = url .. "-L" .. end_line
    end
  end

  return url
end

---Extract "owner/repo" from a remote URL.
---@param remote_url string
---@return string|nil owner_repo
function M.parse_owner_repo(remote_url)
  if not remote_url then
    return nil
  end
  -- SSH: git@github.com:owner/repo.git
  local owner_repo = remote_url:match("github%.com[:/]([%w%.%-_]+/[%w%.%-_]+)")
  if owner_repo then
    return owner_repo:gsub("%.git$", "")
  end
  return nil
end

---Search for PRs containing a commit hash using gh CLI.
---@param hash string commit hash
---@param cwd string directory to run gh from
---@param callback fun(prs: table[]|nil, err: string|nil)
function M.find_prs(hash, cwd, callback)
  local gh = config.values.gh_path
  local state = config.values.pr_state

  vim.system(
    { gh, "pr", "list", "--search", hash, "--state", state, "--json", "number,url", "--limit", "10" },
    { text = true, cwd = cwd },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback(nil, translate_gh_error(result.stderr))
          return
        end
        local prs = M.parse_pr_list(result.stdout)
        callback(prs, nil)
      end)
    end
  )
end

---Parse JSON output from `gh pr view --json number,title,url,state,baseRefName,headRefOid`.
---@param json_str string
---@return table|nil pr_meta {number, title, url, state, base_ref, head_oid}
function M.parse_pr_view(json_str)
  if not json_str or json_str == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, json_str)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  if not decoded.number or not decoded.baseRefName then
    return nil
  end
  return {
    number = decoded.number,
    title = decoded.title,
    url = decoded.url,
    state = decoded.state,
    base_ref = decoded.baseRefName,
    head_oid = decoded.headRefOid,
  }
end

---Fetch PR metadata using gh CLI.
---@param number integer PR number
---@param cwd string directory to run gh from
---@param callback fun(pr_meta: table|nil, err: string|nil)
function M.pr_view(number, cwd, callback)
  local gh = config.values.gh_path

  vim.system(
    { gh, "pr", "view", tostring(number), "--json", "number,title,url,state,baseRefName,headRefOid" },
    { text = true, cwd = cwd },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback(nil, translate_gh_error(result.stderr))
          return
        end
        callback(M.parse_pr_view(result.stdout), nil)
      end)
    end
  )
end

---List open PRs using gh CLI.
---@param cwd string directory to run gh from
---@param callback fun(prs: table[]|nil, err: string|nil)
function M.list_open_prs(cwd, callback)
  local gh = config.values.gh_path
  local limit = config.values.review.pr_list_limit

  vim.system(
    { gh, "pr", "list", "--state", "open", "--json", "number,title,author", "--limit", tostring(limit) },
    { text = true, cwd = cwd },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback(nil, translate_gh_error(result.stderr))
          return
        end
        callback(M.parse_pr_list(result.stdout), nil)
      end)
    end
  )
end

return M
