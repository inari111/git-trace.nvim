# git-trace.nvim

A Neovim plugin to jump from `git blame` to the pull request. Open PRs and files on GitHub — one keystroke from any line to the PR that introduced it.

## Motivation

When reviewing code, you often want to know *why* a line was changed. `git blame` gives you a commit hash, but what you really want is the pull request — with its description, review comments, and full context. **git-trace.nvim** bridges that gap: one keystroke takes you from a line of code to the PR that introduced it.

## Features

- **PR lookup from any line** — Uses `git blame` + `gh pr list` to find the PR that introduced the current line
- **Async execution** — All git/gh operations run asynchronously via `vim.system()`, so your editor never blocks
- **SSH & HTTPS remote support** — Works with both `git@github.com:user/repo.git` and `https://github.com/user/repo.git`
- **Multiple PR selection** — When a commit appears in multiple PRs, a selection dialog lets you choose
- **Open files on GitHub** — Open the current file or visual selection on GitHub with a permalink (pinned to HEAD commit)
- **Copy PR URL** — Copy the PR URL to clipboard instead of opening it

## Requirements

- Neovim >= 0.10.0
- [git](https://git-scm.com/)
- [gh CLI](https://cli.github.com/) (authenticated via `gh auth login`)

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "inari111/git-trace.nvim",
  cmd = { "GitTracePR", "GitTracePRCopy", "GitTraceOpen" },
  keys = {
    { "<leader>gp", "<cmd>GitTracePR<cr>", desc = "Open PR for current line" },
    { "<leader>gy", "<cmd>GitTracePRCopy<cr>", desc = "Copy PR URL for current line" },
    { "<leader>go", "<cmd>GitTraceOpen<cr>", mode = "n", desc = "Open file on GitHub" },
    { "<leader>go", ":'<,'>GitTraceOpen<cr>", mode = "v", desc = "Open selection on GitHub" },
  },
  config = function()
    require("git-trace").setup()
  end,
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use({
  "inari111/git-trace.nvim",
  config = function()
    require("git-trace").setup()
  end,
})
```

## Usage

### Open PR for current line

Place your cursor on any line and run:

```
:GitTracePR
```

This runs `git blame` on the line, finds the PR containing that commit, and opens it in your browser. If multiple PRs match, you'll get a selection dialog.

### Copy PR URL

```
:GitTracePRCopy
```

Same as `:GitTracePR`, but copies the URL to your system clipboard (`+` register) instead of opening a browser.

### Open file/selection on GitHub

In **Normal mode**, open the current file at the cursor line:

```
:GitTraceOpen
```

In **Visual mode**, select a range of lines, then run:

```
:'<,'>GitTraceOpen
```

This opens a GitHub permalink with the exact line range highlighted (e.g., `#L10-L20`).

## Configuration

```lua
require("git-trace").setup({
  pr_state = "merged",   -- PR state filter for search
  gh_path = "gh",        -- path to gh CLI executable
  git_path = "git",      -- path to git executable
})
```

All options are optional. The defaults shown above are used when not specified.

### `pr_state`

Controls which PRs are searched when looking up a commit:

| Value | Description |
|-------|-------------|
| `"merged"` | **(default)** Only search merged PRs. Best for most workflows — avoids noise from abandoned PRs. |
| `"open"` | Only search currently open PRs. Useful for reviewing in-progress work. |
| `"all"` | Search all PRs regardless of state. Use this if you need to find PRs that were closed without merging. |

### `gh_path` / `git_path`

Override the path to the `gh` or `git` executable. Useful if they are installed in a non-standard location or you want to use a wrapper script.

## Commands

| Command | Description | Mode |
|---------|-------------|------|
| `:GitTracePR` | Open the PR for the current line in browser | Normal |
| `:GitTracePRCopy` | Copy the PR URL for the current line to clipboard | Normal |
| `:GitTraceOpen` | Open current file or visual selection on GitHub | Normal, Visual |

## Troubleshooting

### `gh auth login required`

You need to authenticate the GitHub CLI. Run in your terminal:

```sh
gh auth login
```

### `No PR found for commit xxxxxxxx`

This can happen when:

- The commit was pushed directly to the main branch without a PR
- The `pr_state` filter doesn't include the PR's current state (e.g., PR is open but `pr_state` is `"merged"`)
- The commit is too old and not indexed by GitHub's search

Try setting `pr_state = "all"` to broaden the search.

### `No commit found for this line (uncommitted change)`

The current line hasn't been committed yet. Commit your changes first, then retry.

### `Unsupported remote: ...`

Currently only GitHub remotes are supported. GitLab and Bitbucket are not yet supported.

### `gh CLI not found`

Install the GitHub CLI: https://cli.github.com

## License

MIT
