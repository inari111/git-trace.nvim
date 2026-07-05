local M = {}

---@class GitTraceHunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer

---@class GitTraceReviewFile
---@field path string        -- head-side repo-relative path
---@field old_path string|nil -- only set when renamed
---@field status string      -- "A"|"M"|"D"|"R"|"T"
---@field additions integer|nil  -- nil for binary files
---@field deletions integer|nil
---@field binary boolean

---Parse unified diff hunk headers (`@@ -a,b +c,d @@`) from `git diff -U0` output.
---Lines that don't match are ignored. A missing count (e.g. `@@ -3 +3 @@`) defaults to 1.
---@param diff_text string|nil
---@return GitTraceHunk[]
function M.parse_hunks(diff_text)
  local hunks = {}
  if not diff_text or diff_text == "" then
    return hunks
  end

  for line in diff_text:gmatch("[^\n]+") do
    local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if old_start then
      table.insert(hunks, {
        old_start = tonumber(old_start),
        old_count = old_count ~= "" and tonumber(old_count) or 1,
        new_start = tonumber(new_start),
        new_count = new_count ~= "" and tonumber(new_count) or 1,
      })
    end
  end

  return hunks
end

---Parse the NUL-delimited output of `git diff --name-status -z -M`.
---Regular entries are `STATUS\0path\0`; renames/copies are `R100\0old\0new\0`
---(status is normalized to its leading character).
---@param output string|nil
---@return table[] entries {status: string, path: string, old_path: string|nil}
function M.parse_name_status(output)
  local entries = {}
  if not output or output == "" then
    return entries
  end

  local tokens = vim.split(output, "\0", { plain = true })
  local i = 1
  while i <= #tokens and tokens[i] ~= "" do
    local raw_status = tokens[i]
    local status = raw_status:sub(1, 1)
    if status == "R" or status == "C" then
      table.insert(entries, { status = status, path = tokens[i + 2], old_path = tokens[i + 1] })
      i = i + 3
    else
      table.insert(entries, { status = status, path = tokens[i + 1] })
      i = i + 2
    end
  end

  return entries
end

---Parse the NUL-delimited output of `git diff --numstat -z -M`.
---Regular entries are `add\tdel\tpath\0`; binary files use `-\t-\tpath\0`;
---renames are `add\tdel\t\0old\0new\0` (empty path field before the old/new pair).
---@param output string|nil
---@return table[] entries {additions: integer|nil, deletions: integer|nil, path: string, old_path: string|nil}
function M.parse_numstat(output)
  local entries = {}
  if not output or output == "" then
    return entries
  end

  local tokens = vim.split(output, "\0", { plain = true })
  local i = 1
  while i <= #tokens and tokens[i] ~= "" do
    local additions, deletions, path = tokens[i]:match("^([^\t]*)\t([^\t]*)\t(.*)$")
    if not additions then
      i = i + 1
    else
      local entry = {
        additions = additions ~= "-" and tonumber(additions) or nil,
        deletions = deletions ~= "-" and tonumber(deletions) or nil,
      }
      if path == "" then
        entry.old_path = tokens[i + 1]
        entry.path = tokens[i + 2]
        i = i + 3
      else
        entry.path = path
        i = i + 1
      end
      table.insert(entries, entry)
    end
  end

  return entries
end

---Merge `parse_name_status` and `parse_numstat` results (keyed by the head-side path)
---into GitTraceReviewFile entries. Missing numstat entries leave additions/deletions
---nil and binary false. A numstat entry with both counts nil marks the file binary.
---@param name_status table[] from parse_name_status
---@param numstat table[] from parse_numstat
---@return GitTraceReviewFile[]
function M.merge_changed_files(name_status, numstat)
  local numstat_by_path = {}
  for _, entry in ipairs(numstat or {}) do
    numstat_by_path[entry.path] = entry
  end

  local files = {}
  for _, ns in ipairs(name_status or {}) do
    local num = numstat_by_path[ns.path]
    local additions, deletions, binary = nil, nil, false
    if num then
      additions = num.additions
      deletions = num.deletions
      binary = additions == nil and deletions == nil
    end
    table.insert(files, {
      path = ns.path,
      old_path = ns.old_path,
      status = ns.status,
      additions = additions,
      deletions = deletions,
      binary = binary,
    })
  end

  return files
end

---Parse `git worktree list --porcelain` output.
---@param output string|nil
---@return table[] entries {path: string, head: string|nil, branch: string|nil, detached: boolean}
function M.parse_worktree_list(output)
  local entries = {}
  if not output or output == "" then
    return entries
  end

  local current = nil
  for line in (output .. "\n"):gmatch("([^\n]*)\n") do
    if line == "" then
      if current then
        table.insert(entries, current)
        current = nil
      end
    else
      local path = line:match("^worktree (.+)$")
      if path then
        current = { path = path, detached = false }
      elseif current then
        local head = line:match("^HEAD (.+)$")
        local branch = line:match("^branch (.+)$")
        if head then
          current.head = head
        elseif branch then
          current.branch = branch
        elseif line == "detached" then
          current.detached = true
        end
      end
    end
  end
  if current then
    table.insert(entries, current)
  end

  return entries
end

return M
