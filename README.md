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
- (Optional but recommended) [`fd`](https://github.com/sharkdp/fd)

> [!TIP]
> Install [`fd`](https://github.com/sharkdp/fd) for a faster and more capable `/` fallback search. The plugin detects it automatically and falls back to `find` if it's missing. Directory listing itself needs neither — it uses one `readdir` per expanded folder.

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

On top of that, **every** `/` also searches the whole tree with `fd` (or `find`) — a match on screen tells you nothing about how many more are still unloaded on disk. For each hit filebuf expands only the folders leading to it, so a match at `a/b/c/file.txt` loads `a`, `b` and `c` while sibling subfolders of each are listed but left collapsed.

Every match is highlighted with `FilebufSearchMatch`. The cursor stays put if it's already on a match (as it will be when the native search found one) and otherwise jumps to the topmost match; `n`/`N` then cycle through them as usual.

Because unloaded entries aren't in the buffer, Vim's own `E486: Pattern not found` would fire before filebuf gets a chance to look on disk, so it is suppressed — you only get `pattern not found` when the pattern matches neither the buffer nor anything on disk.

Hidden and ignored entries are only searched when they'd actually be displayable, i.e. when `show_hidden` is on.

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

    -- Respect .gitignore / .ignore patterns
    respect_ignore = true,

    -- Confirm operations before saving
	save_confirmation = true,

    -- Use filebuf instead of netrw when opening directories
    hijack_netrw = true,

    -- Default sort method, can change with FilebufSortMethod <method>
    sort_method = "type",

    -- Max hits revealed by the `/` fallback search
    search_max_results = 500,

    -- Max entries a single recursive expand (zO) may load
    max_expand_entries = 20000,

    -- Confirm before a recursive expand (zO) this large; false to never ask
    expand_confirm_threshold = 1000,

    -- Customize or disable keymaps (set to false to disable)
    keymaps = {
        fold_open = "zo",
        fold_close = "zc",
        fold_toggle = "za",
        fold_open_recursive = "zO",
        fold_open_all = "zR",
        fold_close_all = "zM",
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
