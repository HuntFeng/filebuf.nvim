# filebuf.nvim

A minimalistic, zero-dependency, intuitive tree-based filesystem editor for Neovim.

https://github.com/user-attachments/assets/73cdb1af-f5a9-4978-ba11-f3a5868cfb8e

:construction: Early stage plugin, expect changes :construction:

## Features

- **Editable tree** - create, rename, delete and search files/dirs in a buffer, save with `:w`.
- **Indent-based folding** - directories fold like code.
- **Git status** - per-file and per-directory git indicators (added, modified, untracked,...).
- **Diagnostics** - when wrong operations occur, buffer won't save and shows diagnostics.
- **Respect .gitignore** - hidden & ignored entries are hidden by default and will be loaded upon expansion.
- **Netrw hijack** - can open filebuf instead of netrw when `nvim .`, `:e <dir>` and `Ex .` etc.

## Installation

### Requirements
- neovim >= 0.10.0
- git  (preinsatlled on most linux distros)
- find (preinsatlled on most linux distros)
- (Optional but recommended) [`fd`](https://github.com/sharkdp/fd)

> [!TIP]
> Install [`fd`](https://github.com/sharkdp/fd) for dramatically faster scanning on large repositories. The plugin detects it automatically and falls back to `find` if it's missing.

`lazy.nvim` or other similar package manager
```lua
{
  "HuntFeng/filebuf.nvim",
  opts = {},
  -- don't lazy load it if you want to hijack netrw
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

    -- Default sort method, can change with FilebufSortMethod <method>
    sort_method = "type",

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
