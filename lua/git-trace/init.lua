local config = require("git-trace.config")
local git = require("git-trace.git")
local provider_resolver = require("git-trace.provider")

local M = {}

---@param opts? table
function M.setup(opts)
  config.apply(opts)

  vim.api.nvim_create_user_command("GitTracePR", function()
    M.open_pr()
  end, { force = true, desc = "Open PR for current line in browser" })

  vim.api.nvim_create_user_command("GitTracePRCopy", function()
    M.copy_pr_url()
  end, { force = true, desc = "Copy PR URL for current line" })

  vim.api.nvim_create_user_command("GitTraceOpen", function(cmd_opts)
    M.browse_open(cmd_opts)
  end, { force = true, range = true, desc = "Open file/selection on GitHub" })
end

---Open PR for the current cursor line.
function M.open_pr()
  local file = vim.api.nvim_buf_get_name(0)
  local line = vim.api.nvim_win_get_cursor(0)[1]

  if file == "" then
    vim.notify("[git-trace] No file in current buffer", vim.log.levels.WARN)
    return
  end

  local dir = vim.fn.fnamemodify(file, ":h")

  git.blame_line(file, line, function(hash, err)
    if err then
      vim.notify("[git-trace] " .. err, vim.log.levels.ERROR)
      return
    end
    if not hash then
      vim.notify("[git-trace] No commit found for this line (uncommitted change)", vim.log.levels.WARN)
      return
    end

    local github = require("git-trace.provider.github")
    github.find_prs(hash, dir, function(prs, pr_err)
      if pr_err then
        vim.notify("[git-trace] " .. pr_err, vim.log.levels.ERROR)
        return
      end
      if not prs or #prs == 0 then
        vim.notify("[git-trace] No PR found for commit " .. hash:sub(1, 8), vim.log.levels.INFO)
        return
      end

      if #prs == 1 then
        vim.ui.open(prs[1].url)
      else
        vim.ui.select(prs, {
          prompt = "Select PR to open:",
          format_item = function(pr)
            return ("#%d - %s"):format(pr.number, pr.url)
          end,
        }, function(selected)
          if selected then
            vim.ui.open(selected.url)
          end
        end)
      end
    end)
  end)
end

---Copy PR URL for the current cursor line to clipboard.
function M.copy_pr_url()
  local file = vim.api.nvim_buf_get_name(0)
  local line = vim.api.nvim_win_get_cursor(0)[1]

  if file == "" then
    vim.notify("[git-trace] No file in current buffer", vim.log.levels.WARN)
    return
  end

  local dir = vim.fn.fnamemodify(file, ":h")

  git.blame_line(file, line, function(hash, err)
    if err then
      vim.notify("[git-trace] " .. err, vim.log.levels.ERROR)
      return
    end
    if not hash then
      vim.notify("[git-trace] No commit found for this line (uncommitted change)", vim.log.levels.WARN)
      return
    end

    local github = require("git-trace.provider.github")
    github.find_prs(hash, dir, function(prs, pr_err)
      if pr_err then
        vim.notify("[git-trace] " .. pr_err, vim.log.levels.ERROR)
        return
      end
      if not prs or #prs == 0 then
        vim.notify("[git-trace] No PR found for commit " .. hash:sub(1, 8), vim.log.levels.INFO)
        return
      end

      if #prs == 1 then
        vim.fn.setreg("+", prs[1].url)
        vim.notify("[git-trace] Copied: " .. prs[1].url, vim.log.levels.INFO)
      else
        vim.ui.select(prs, {
          prompt = "Select PR to copy URL:",
          format_item = function(pr)
            return ("#%d - %s"):format(pr.number, pr.url)
          end,
        }, function(selected)
          if selected then
            vim.fn.setreg("+", selected.url)
            vim.notify("[git-trace] Copied: " .. selected.url, vim.log.levels.INFO)
          end
        end)
      end
    end)
  end)
end

---Open current file or visual selection on GitHub.
---@param cmd_opts? table command options from nvim_create_user_command
function M.browse_open(cmd_opts)
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    vim.notify("[git-trace] No file in current buffer", vim.log.levels.WARN)
    return
  end

  local start_line = nil
  local end_line = nil

  if cmd_opts and cmd_opts.range == 2 then
    start_line = cmd_opts.line1
    end_line = cmd_opts.line2
  else
    start_line = vim.api.nvim_win_get_cursor(0)[1]
  end

  local dir = vim.fn.fnamemodify(file, ":h")

  git.repo_root(dir, function(root, root_err)
    if root_err or not root then
      vim.notify("[git-trace] " .. (root_err or "Not a git repository"), vim.log.levels.ERROR)
      return
    end

    local rel_path = file:sub(#root + 2)

    git.remote_url(dir, function(remote_url, remote_err)
      if remote_err or not remote_url then
        vim.notify("[git-trace] " .. (remote_err or "No remote found"), vim.log.levels.ERROR)
        return
      end

      local provider = provider_resolver.resolve(remote_url)
      if not provider then
        vim.notify("[git-trace] Unsupported remote: " .. remote_url, vim.log.levels.ERROR)
        return
      end

      git.head_hash(dir, function(hash, hash_err)
        if hash_err or not hash then
          vim.notify("[git-trace] " .. (hash_err or "Failed to get HEAD"), vim.log.levels.ERROR)
          return
        end

        local url = provider.build_file_url(remote_url, hash, rel_path, start_line, end_line)
        if not url then
          vim.notify("[git-trace] Failed to build URL", vim.log.levels.ERROR)
          return
        end

        vim.ui.open(url)
      end)
    end)
  end)
end

return M
