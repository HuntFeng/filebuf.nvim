# filebuf.nvim

Edit your filesystem as a Neovim buffer. The entire directory tree is rendered into a single editable buffer with indent-based folding — rename, create, and delete files by editing lines, then `:w` to apply. No sidebars, no netrw. Just a buffer.

> 📺 **[Demo video coming soon]**

## Features

- **Editable tree** — create, rename, and delete files by editing the buffer. Diffs are validated and applied on `:w`.
- **Indent-based folding** — directories fold like code. Fold state is persisted across sessions.
- **Git status** — per-file and per-directory git indicators (added, modified, untracked, conflicted).
- **Lazy loading** — hidden and ignored directories are loaded on demand when you expand them.
- **Netrw hijack** — `nvim .` and `:e <dir>` open filebuf instead of netrw (configurable).
- **Cursor-aware auto-focus** — when opening, the tree expands to reveal and center the file you were just editing.
- **Configurable keymaps** — all bindings overrideable, standard vim-fold keys by default.
- **Fast scanning** — uses `fd` when available for near-instant scans on large repos, with a `find` fallback.

## Installation

### Dependencies
- git  (most linux machines has it)
- find (most linux machines has it)
- (Optional but recommand) [`fd`](https://github.com/sharkdp/fd)

> [!TIP]
> Install [`fd`](https://github.com/sharkdp/fd) for dramatically faster scanning on large repositories. The plugin detects it automatically and falls back to `find` if it's missing.

### lazy.nvim / vim.pack

```lua
{
  "HuntFeng/filebuf.nvim",
  config = function()
    require("filebuf").setup()
  end,
}
```

## Usage

Open the filebuf browser at the current directory:

```
:Filebuf
```

| Key | Action |
|-----|--------|
| `<CR>` | Toggle directory fold / open file |
| `zo` / `zc` / `za` | Open / close / toggle fold |
| `zO` | Recursively open folds |
| `zR` / `zM` | Open / close all folds |
| `gh` | Toggle hidden (dot) files |
| `q` | Close the filebuf buffer |

Edit any entry name inline, then `:w` to apply the changes to disk. The plugin validates your edits before writing — type mismatches (e.g., removing the indent that makes a file a child of a directory) are caught and reported.

## Configuration

Pass options to `setup()`:

```lua
require("filebuf").setup({
    -- Move deleted files to a /tmp/filebuf_trash directory instead of removing them
    permanent_delete = false,

    -- Auto-focus the file you were editing before opening filebuf
    auto_focus_current_file = true,

    -- Show git status indicators
    git_status = true,

    -- Show hidden (dot) files by default
    show_hidden = false,

    -- Respect .gitignore / .ignore patterns
    respect_ignore = true,

    -- Use filebuf instead of netrw when opening directories
    hijack_netrw = true,

    -- Customize or disable keymaps (set to false to disable)
    keymaps = {
        fold_open = "zo",
        fold_close = "zc",
        fold_toggle = "za",
        fold_open_recursive = "zO",
        fold_open_all = "zR",
        fold_close_all = "zM",
        open_or_toggle = "<CR>",
        toggle_hidden = "gh",
        close_filebuf = "q",
    },
})
```

### Highlight groups

Override these to match your colorscheme:

| Group | Purpose |
|-------|---------|
| `FilebufGitAdded` | Git-added entries |
| `FilebufGitModified` | Git-modified entries |
| `FilebufGitDeleted` | Git-deleted entries |
| `FilebufGitUntracked` | Git-untracked entries |
| `FilebufGitConflict` | Merge-conflicted entries |
| `FilebufGitRenamed` | Git-renamed entries |
| `FilebufHiddenFile` | Hidden (dot) files |
| `FilebufHiddenDir` | Hidden directories |
| `FilebufLink` | Symlinks |
| `FilebufFoldLine` | Fold line background |
