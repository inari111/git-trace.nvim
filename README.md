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
- **Review PRs in Neovim** — Check out a PR into a disposable worktree and review it as a native diff, with quickfix file navigation and your LSP running on the real PR code

## Requirements

- Neovim >= 0.10.0
- [git](https://git-scm.com/)
- [gh CLI](https://cli.github.com/) (authenticated via `gh auth login`)

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "inari111/git-trace.nvim",
  cmd = { "GitTracePR", "GitTracePRCopy", "GitTraceOpen", "GitTraceReview", "GitTraceReviewClose", "GitTraceReviewClean" },
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

## PR Review

Review a GitHub pull request without leaving Neovim. `:GitTraceReview` fetches the PR into a disposable git worktree checked out at the PR head, populates the quickfix list with the changed files, and shows each file as a native side-by-side diff against the merge base. Because the PR is checked out as real files in a worktree, your LSP, treesitter, and other tools operate on the actual PR code.

### Commands

| Command | Description |
|---------|-------------|
| `:GitTraceReview [number]` | Open a PR review session. With a PR number, reviews that PR; with no argument, prompts to select from the open PRs. |
| `:GitTraceReviewClose` | Close the current review session (leaves the worktree on disk for fast reopening). |
| `:GitTraceReviewClean` | Remove all git-trace review worktrees to reclaim disk space (asks for confirmation). |

### Keymaps

While a review session is active, these buffer-local keymaps are set on the review buffers only (they do not affect any other buffer):

| Key | Action |
|-----|--------|
| `<leader>rd` | Toggle between diff and single-file view |
| `]f` | Jump to the next changed file |
| `[f` | Jump to the previous changed file |
| `]c` | Jump to the next hunk (native diff jump in diff view, sign-based in single view) |
| `[c` | Jump to the previous hunk |
| `<leader>rq` | Close the review session |

Set `review.keymaps = false` to disable all review keymaps, or set an individual key to `false` to disable just that one:

```lua
require("git-trace").setup({
  review = {
    keymaps = false, -- disable all review keymaps
  },
})
```

### Configuration

```lua
require("git-trace").setup({
  review = {
    worktree_dir = nil,   -- worktree base dir; nil = stdpath("cache").."/git-trace/worktrees"
    pr_list_limit = 30,   -- max PRs listed when selecting with `:GitTraceReview`
    open_qf = true,       -- open the quickfix window automatically
    close_qf_on_open = true, -- close the quickfix window when a review file opens, so the diff gets full height
    keymaps = {
      toggle_diff = "<leader>rd",
      next_file = "]f",
      prev_file = "[f",
      next_hunk = "]c",
      prev_hunk = "[c",
      close = "<leader>rq",
    },
  },
})
```

### Notes

- **Worktrees are disposable.** Each PR is checked out with a detached HEAD under `~/.cache/nvim/git-trace/worktrees/` (`vim.fn.stdpath("cache")`). Reopening a PR runs `git checkout --force`, so any edits you make inside a review worktree are discarded — treat it as read-only.
- **`:GitTraceReviewClose` keeps the worktree** on disk so reopening the same PR is fast. Run `:GitTraceReviewClean` when you want to reclaim the disk space.
- **Navigate files with `]f` / `[f`** (or `require("git-trace.review").next_file()` / `prev_file()`). Running the raw `:cnext` from the base (left) diff window opens the next file in the wrong window and breaks the layout; the navigation commands focus the correct window first.
- **Opening a file closes the quickfix window** so the diff fills the full height (`close_qf_on_open`, default `true`). File navigation still works with `]f` / `[f`; run `:copen` to bring the file list back.
- **Opening a file also closes any dashboard window** (snacks.nvim, dashboard-nvim, alpha-nvim, mini.starter, vim-startify). When `:GitTraceReview` is run from a start screen, quickfix opens the file in a small split beside it; the dashboard is closed so the diff fills the screen.
- **LSP runs as a separate instance** rooted at the worktree directory. Language ecosystems that need installed dependencies (e.g. `node_modules`) will not be fully functional unless those dependencies are present in the worktree.

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
| `:GitTraceReview [number]` | Review a GitHub PR in Neovim (worktree + native diff) | Normal |
| `:GitTraceReviewClose` | Close the current PR review session | Normal |
| `:GitTraceReviewClean` | Remove all git-trace review worktrees | Normal |

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
