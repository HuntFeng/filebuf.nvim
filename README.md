# filebuf.nvim

A minimalistic, zero-dependency, intuitive tree-based filesystem editor for Neovim.

https://github.com/user-attachments/assets/06ad1be1-f862-4bfe-a4ea-e37d05cd9b6b

:construction: Early stage plugin, expect changes :construction:

## Features

- **Editable tree** - create, rename, delete and move files/dirs in a buffer, save with `:w`.
- **Lazy loading** - only one directory level is read at a time, so opening a 100k-file repo is instant.
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

Open the filebuf browser at the current directory:

```
:Filebuf
```

Edit any entry name inline, then `:w` to apply the changes to disk. The plugin validates your edits before writing — type mismatches (e.g., removing the indent that makes a file a child of a directory) are caught and reported.

### Lazy loading

Every directory is loaded on demand. Opening a filebuf reads only the root's immediate children; a folder's contents appear when you expand it (`<CR>`, `zo`, `za`) or when a search reveals a path through it. Nothing is read ahead of time, so the cost of opening a tree is independent of its size.

Three things follow from that:

- Unexpanded folders have no fold yet, so no `▶` appears in the foldcolumn — the trailing `/` is the cue.
- `zR` reveals one more level per press rather than the whole tree.
- `zO` expands a whole subtree. It counts the subtree first and asks for confirmation past `expand_confirm_threshold` entries, and stops outright at `max_expand_entries`.

### Searching

`/` is left alone: native incremental search, history and `n`/`N` all behave normally.

On top of that, **every** `/` also searches the whole tree with `find(1)` — a match on screen tells you nothing about how many more are still unloaded on disk. For each hit filebuf expands only the folders leading to it, so a match at `a/b/c/file.txt` loads `a`, `b` and `c` while sibling subfolders of each are listed but left collapsed.

Every match is highlighted with `FilebufSearchMatch`. The cursor stays put if it's already on a match (as it will be when the native search found one) and otherwise jumps to the topmost match; `n`/`N` then cycle through them as usual.

Because unloaded entries aren't in the buffer, Vim's own `E486: Pattern not found` would fire before filebuf gets a chance to look on disk, so it is suppressed — you only get `pattern not found` when the pattern matches neither the buffer nor anything on disk.

Hidden and ignored entries are only searched when they'd actually be displayable, i.e. when `show_hidden` is on.

**Async find mode** (`search.enter`) replaces the buffer with only the matching entries, streaming results as they arrive.  Exit with `<Esc>` to restore the previous view.

```lua
-- Bind g/ to enter find mode (not bound by default):
vim.keymap.set("n", "g/", function()
    filebuf.search()
    -- filebuf.search({ skip_hidden = false }) -- search everything, including hidden files
end, { desc = "Search mode" })
```

**`search()` Lua API** opens a filebuf (if not already in one) and enters find mode.  Ignored directories are pruned by default; pass `respect_ignored = false` to search everything.

```lua
vim.keymap.set("n", "g/", function()
  require("filebuf").search()                     -- respect .gitignore
  -- require("filebuf").search({ respect_ignored = false })  -- search everything
end, { desc = "filebuf: search tree" })
```

| Command | Purpose |
|---------|---------|
| `:FilebufFind <pattern>` | Run the tree-wide search directly, without going through `/` |
| `:FilebufSearchClear` | Drop the match highlighting |

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

    -- Confirm operations before saving
	save_confirmation = true,

    -- Use filebuf instead of netrw when opening directories
    hijack_netrw = true,

    -- Default sort method, can change with FilebufSortMethod <method>
    sort_method = "type",

	--- Dirs deeper this are listed but their children are lazy loaded
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
| `FilebufFoldLine` | Fold line background |
