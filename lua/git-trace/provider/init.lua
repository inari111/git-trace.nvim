local M = {}

---Resolve the provider based on remote URL.
---Currently only GitHub is supported.
---@param remote_url string
---@return table|nil provider module
function M.resolve(remote_url)
  if not remote_url then
    return nil
  end
  if remote_url:match("github%.com") then
    return require("git-trace.provider.github")
  end
  return nil
end

return M
