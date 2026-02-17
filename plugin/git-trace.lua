if vim.g.loaded_git_trace then
  return
end
vim.g.loaded_git_trace = true

if vim.fn.has("nvim-0.10.0") == 0 then
  vim.notify("[git-trace] Requires Neovim >= 0.10.0", vim.log.levels.ERROR)
  return
end
