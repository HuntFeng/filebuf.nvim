# filebuf.nvim

A minimalistic, zero-dependency, intuitive tree-based filesystem editor for Neovim.

https://github.com/user-attachments/assets/06ad1be1-f862-4bfe-a4ea-e37d05cd9b6b

:construction: Early stage plugin, expect changes :construction:

## Features

- **Editable tree** - create, rename, delete and move files/dirs in a buffer, save with `:w`.
- **Yank & paste** - `gy` marks files/dirs (works on a visual selection too), `gp` pastes them; directories copy recursively.
- **Indent-based folding** - directories fold like code.
- **Git status** - per-file and per-directory git indicators (added, modified, untracked,...).
- **Diagnostics** - when wrong operations occur, buffer won't save and shows diagnostics.
- **Respect .gitignore** - hidden & ignored entries are listed but filtered out by default; `gh` toggles them instantly.
- **Search that loads on demand** - `/` works as usual, then also searches the whole tree and expands just the folders leading to each hit.
- **Netrw hijack** - can open filebuf instead of netrw when `nvim .`, `:e <dir>` and `Ex .` etc.

## Installation

### Requirements
- neovim >= 0.10.0
- git  (preinsatlled on most linux distros)
- find (preinsatlled on most linux distros)

`lazy.nvim` or other similar package manager
```lua
{
  "HuntFeng/filebuf.nvim",
  opts = {},
  -- don't lazy load it if you want to hijack netrw
}
```

## Usage

- Open the filebuf with `:Filebuf` or `:Filebuf <dir>` to open a specific directory.
- If `hijack_netrw = true`, then `:e <dir>` or `:Ex` (or other related commands) will also open filebuf.
- Use neovim's native fold commands to navigate the tree, read more about folds in `:help fold-commands` or [fold-commands](https://neovim.io/doc/user/fold/#_2.-fold-commands).
Some frequent commands I find useful:
    - `za` to toggle fold under cursor
    - `zO` to open all folds recursively under cursor
    - `zR` to open all folds in the tree
    - `zM` to close all folds in the tree
    - `[z` to jump to the last fold
    - `]z` to jump to the next fold
    - `gf` to open the file under the cursor in a new buffer
    - `<CR>` to open the file or toggle the directory under the cursor
    - `K` to toggle the preview window, `K` again to focus
- Copy entries with `gy` then `gp`:
    - `gy` marks the entry under the cursor (or the whole visual selection) and tags it `(copy)`; a marked directory tags its children too, because the copy is recursive. `gy` again on the same entry unmarks it.
    - `gp` pastes a line per marked entry — inside the directory under the cursor, or beside the file under the cursor.
    - The pasted line stays bound to its source even if you rename it, which you have to do when copying into the source's own directory: two siblings cannot share a name.
- Finished edits, use `:w` to apply the changes to disk.

## Commands
| Command | Action |
|-------|---------|
| `Filebuf` | Open / Refresh filebuf |
| `FilebufSortMethod <method>` | Sort entries with method (name, type, created, modified) |
| `FilebufToggleHidden` | Toggle hidden / ignored entries |
| `FilebufFind <pattern>` | Enter find mode and search for `<pattern>`|


## Configuration

Pass options to `setup()`:

```lua
require("filebuf").setup({
    -- Default to move deleted files to a /tmp/filebuf_trash directory instead of removing them
    permanent_delete = false,

    -- Auto-focus the file you were editing before opening filebuf
    auto_focus_current_file = true,

    -- Show git status indicators
    git_status = true,

    -- Show hidden (dot) files by default
    show_hidden = false,

    -- Confirm operations before saving
	save_confirmation = true,

    -- Use filebuf instead of netrw when opening directories
    hijack_netrw = true,

    -- Default sort method, can change with FilebufSortMethod <method>
    -- Options: "name", "type", "created", "modified"
    sort_method = "type",

	--- The tree is scanned to this depth
	max_depth = 20,

    -- Customize or disable keymaps (set to false to disable)
    keymaps = {
		-- Directory are neovim's native folds
        -- Here are some useful built-in keymaps for folds in neovim
        -- Remap them to your liking if or leave them as they are
		-- fold close = "zc",
		-- fold toggle = "za",
		-- fold open recursive = "zO",
		-- fold open all = "zR",
		-- fold close all = "zM",
        -- last fold = "[z"
        -- next fold = "]z"
        open_file = "gf",
        open_or_toggle = "<CR>",
        toggle_preview = "K",
        toggle_hidden = "gh",
        close_filebuf = "q",
        copy = "gy", -- normal: entry under cursor; visual: the selection
        paste = "gp",
        find_mode = "g/", -- skips hidden / ignored entries
		find_mode_full = "",
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
| `FilebufSearchMatch` | Entries revealed by the `/` fallback search (links to `Search`) |
| `FilebufCopyMark` | The `(copy)` tag on yanked entries (links to `Comment`) |
| `FilebufFoldLine` | Fold line background |
