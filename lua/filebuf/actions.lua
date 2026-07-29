----------------------------------------------------------------------
-- Public API for fold / lazy-expand / entry-open operations.
--
-- Every function takes `buf` (the filebuf buffer number) plus an
-- `entry` table when applicable.  None of them read cursor position
-- internally — the caller resolves the cursor to an entry first so
-- the functions can be called from arbitrary keymaps or scripts.
--
-- Folds are not built here: 'foldexpr' (FilebufFoldExpr below) derives
-- every fold range from a line's indentation and its trailing "/", so
-- Neovim maintains them itself and recomputes only what a buffer change
-- touched.  What is left is open/closed state, which the plugin persists
-- per root in M.open_folds.
--
-- That state is authoritative, not derived: it is updated as folds are
-- opened and closed, never recovered by scanning the buffer and asking
-- foldclosed() about every directory.  Reading it back cost a full-buffer
-- walk plus a vim.fn call per directory on every render *and* every fold
-- keystroke, which on a large tree was the single most expensive thing the
-- plugin did.
----------------------------------------------------------------------
local prof = require("filebuf.profiler")
local config = require("filebuf.config")
local scan = require("filebuf.scan")
local state = require("filebuf.state")
local line_mod = require("filebuf.line")
local buffer = require("filebuf.buffer")
local git = require("filebuf.git")

local M = {}

--- Persisted fold state, keyed by root directory.  Each value is the set of
--- directory paths whose fold is open; survives buffer close/reopen so the
--- user's fold preferences stick.
---
--- Open rather than closed, because "all closed" is the baseline a render
--- starts from (`zM`): an empty set is the default, so nothing ever has to
--- enumerate every directory in the tree just to say "untouched".
M.open_folds = {}

--- The open-fold set for `root`, created on first use.
---@param root string
---@return table  path → true
function M.open_set(root)
	local set = M.open_folds[root]
	if not set then
		set = {}
		M.open_folds[root] = set
	end
	return set
end

--- Record that `path`'s fold is now open (or, with `open` false, closed).
---@param root string|nil
---@param path string|nil
---@param open boolean
function M.mark_open(root, path, open)
	if not root or not path then
		return
	end
	M.open_set(root)[path] = open or nil
end

--- Required lazily: render needs actions for fold rebuilding, and
--- actions needs render for expand/reveal re-renders.
local function render()
	return require("filebuf.render")
end

----------------------------------------------------------------------
-- Line parsing helpers
----------------------------------------------------------------------

--- Parse one buffer line and return its fields.
---@param line string
---@return string|nil name
---@return string|nil type_  "dir"|"link"|"file"
---@return number|nil indent
local function read_line(line)
	if not line then
		return nil
	end
	local name, is_dir, is_link = line_mod.parse_line(line)
	if name == "" then
		return nil
	end
	return name, (is_dir and "dir" or (is_link and "link" or "file")), line_mod.indent_level(line)
end

----------------------------------------------------------------------
-- Fold computation ('foldexpr')
----------------------------------------------------------------------

--- Cached indent settings for the fold expression.  The expression runs
--- once per buffer line — 100k+ times on a large tree — and reading
--- vim.go there costs more than the rest of the expression put together,
--- so the values are cached and invalidated explicitly (see the OptionSet
--- autocmd registered in filebuf.setup).
local indent_cfg = nil

--- Fold levels as strings, so the once-per-line expression returns an
--- interned constant instead of allocating through tostring.  Levels beyond
--- this fall back to tostring; max_depth defaults to 20.
local LEVEL_STR = {}
for i = 0, 32 do
	LEVEL_STR[i] = tostring(i)
end

--- How one level of indent is spelled in the buffer.  Mirrors
--- line.indent_str / line.indent_level, which drive the rendering side.
---@return table  { tabs: boolean, width: number }
local function fold_indent_cfg()
	if not indent_cfg then
		local sw = vim.go.shiftwidth
		indent_cfg = {
			tabs = not vim.go.expandtab,
			width = (sw > 0 and sw) or vim.go.tabstop,
		}
	end
	return indent_cfg
end

--- Drop the cached indent settings.
function M.invalidate_indent_cache()
	indent_cfg = nil
end

--- Indent depth of a buffer line, plus whether the line holds no entry at
--- all.  Same result as line.indent_level, without its per-call option
--- lookups.
---@param line string
---@param cfg  table
---@return number level
---@return boolean blank
local function fold_level_of(line, cfg)
	local ws = (cfg.tabs and line:match("^\t*") or line:match("^ *")) or ""
	if #ws == #line then
		return 0, true
	end
	if cfg.tabs then
		return #ws, false
	end
	return math.floor(#ws / cfg.width), false
end

--- Fold-level callback (v:lua.FilebufFoldExpr), evaluated once per line.
---
--- A directory owns a fold spanning its descendants: it starts a fold one
--- level deeper than itself, and its children — indented one level more —
--- fall inside it.  A directory with nothing deeper after it starts no
--- fold, so empty and unexpanded folders keep a clean fold column.
---
--- The current and the following line arrive in a single
--- nvim_buf_get_lines call; the following line is what says whether the
--- directory has children.
---@return string
function _G.FilebufFoldExpr()
	local lnum = vim.v.lnum

	-- Snapshot fast path.  This expression is evaluated once per line, so on a
	-- 100k-line tree the version below costs 100k nvim_buf_get_lines calls, a
	-- table allocation each, plus a tostring -- paid again on every re-render,
	-- since writing the lines is what makes Neovim recompute the folds.  Off
	-- the snapshot it is two array reads and no allocation.
	local st = state.get(vim.api.nvim_get_current_buf())
	if st and st.snap_clean and st.snap then
		local snap = st.snap
		local row = snap.view[lnum]
		if not row then
			return "0"
		end
		local level = snap.indent[row]
		if snap.kind[row] % 4 == 1 then -- KIND_DIR
			local next_row = snap.view[lnum + 1]
			if next_row and snap.indent[next_row] > level then
				return ">" .. (level + 1)
			end
		end
		return LEVEL_STR[level] or tostring(level)
	end

	local lines = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum + 1, false)
	local line = lines[1]
	if not line then
		return "0"
	end

	local cfg = fold_indent_cfg()
	local level, blank = fold_level_of(line, cfg)
	if blank then
		-- Keep blank lines (mid-edit, mostly) inside the enclosing fold.
		return "="
	end

	if line:sub(-1) == "/" and lines[2] then
		local next_level, next_blank = fold_level_of(lines[2], cfg)
		if not next_blank and next_level > level then
			return ">" .. (level + 1)
		end
	end
	return LEVEL_STR[level] or tostring(level)
end

----------------------------------------------------------------------
-- Fold state restore
----------------------------------------------------------------------

--- Close every fold, then re-open the directories `open_dirs` selects.
---
--- Nothing here creates folds — 'foldexpr' derives them from the buffer
--- text.  A render only has to reset the open/closed state, and `zM` gives
--- a deterministic all-closed baseline: it also pulls 'foldlevel' back to
--- 0, so folds computed after this point start closed too.
---
--- `open_dirs` is either a set of paths to open or a predicate on the path.
--- Directories are visited in buffer order, so a parent is opened before
--- its children (`:foldopen` acts on the outermost closed fold at a line).
---
--- The pass also *records* the resulting open set in M.open_folds, which is
--- why nothing has to read fold state back afterwards: `zM` put every fold
--- in a known state, and this function is what changes it.
---
--- `entries` skips the buffer scan when the caller already holds the
--- rendered entries in memory (find mode).
---@param buf       number
---@param open_dirs table|fun(path: string): boolean|nil
---@param entries   table[]|nil  rendered entries, each carrying lnum and path
function M.restore_folds(buf, open_dirs, entries)
	prof.start("restore_folds")
	vim.cmd("silent! normal! zM")

	local root = state.root(buf)
	-- Post-zM every fold is closed; anything opened below is added back.
	local recorded = {}
	if root then
		M.open_folds[root] = recorded
	end

	if not open_dirs then
		prof.stop()
		return
	end
	local is_open = type(open_dirs) == "function" and open_dirs or function(path)
		return open_dirs[path]
	end

	local function open_dir(lnum, path)
		if is_open(path) then
			vim.cmd(string.format("silent! %dfoldopen", lnum))
			recorded[path] = true
		end
	end

	if entries then
		for _, e in ipairs(entries) do
			if e.type == "dir" then
				open_dir(e.lnum, e.path)
			end
		end
		prof.stop()
		return
	end

	-- Nothing to open: zM already left every fold closed.  Worth checking,
	-- because after the first render open_folds[root] is an empty-but-truthy
	-- table, and without this the walk below runs over the whole tree to
	-- discover it has no work to do.
	if type(open_dirs) == "table" and next(open_dirs) == nil then
		prof.stop()
		return
	end

	local st = state.get(buf)
	if root and st and st.snap_clean and st.snap and type(open_dirs) == "table" then
		-- Resolve the wanted paths to rows once, then scan the projection for
		-- those rows.  Building a path for every directory just to test set
		-- membership costs one string concat per directory on a tree that can
		-- have tens of thousands of them; this pays only for the few that are
		-- actually open.
		local snapshot = require("filebuf.snapshot")
		local snap = st.snap
		local open_rows = {}
		for path in pairs(open_dirs) do
			local row = snapshot.row_of_path(snap, path)
			if row then
				open_rows[row] = path
			end
		end
		local view = snap.view
		for lnum = 1, #view do
			local path = open_rows[view[lnum]]
			if path then
				vim.cmd(string.format("silent! %dfoldopen", lnum))
				recorded[path] = true
			end
		end
		prof.stop()
		return
	end

	if root then
		state.walk(buf, root, function(lnum, path, type_)
			if type_ == "dir" then
				open_dir(lnum, path)
			end
		end)
	end
	prof.stop()
end

--- Record every directory in the subtree at `entry` as open — the bookkeeping
--- half of `zO`.  With `entry` nil the whole buffer is marked (`zR`).
---
--- Neovim opens the nested folds itself but says nothing about which, so
--- this is the one place a walk is unavoidable.  It is still cheap next to
--- what zO/zR do first: load the subtree off disk.
---@param buf    number
---@param entry? table
local function mark_subtree_open(buf, entry)
	local root = state.root(buf)
	if not root then
		return
	end
	local set = M.open_set(root)

	if not entry then
		state.walk(buf, root, function(_, path, type_)
			if type_ == "dir" then
				set[path] = true
			end
		end)
		return
	end

	set[entry.path] = true
	local resolve = state.range_resolver(buf)
	for lnum = entry.lnum + 1, vim.api.nvim_buf_line_count(buf) do
		local e = resolve(lnum)
		if e then
			if e.indent <= entry.indent then
				break -- left the subtree
			end
			if e.type == "dir" then
				set[e.path] = true
			end
		end
	end
end

--- Fold-text callback (v:lua.FilebufFoldText).  Shows the entry name with
--- its indent converted to spaces so it aligns regardless of tabstop.
function _G.FilebufFoldText()
	local line = vim.fn.getline(vim.v.foldstart)
	local indent_ws = line:match("^(%s*)") or ""
	local name = line:match("^%s*(.-)%s*$") or line
	local buf = vim.api.nvim_get_current_buf()
	local entry = state.resolve_entry(buf, vim.v.foldstart)
	local text = string.rep(" ", vim.fn.strdisplaywidth(indent_ws)) .. name
	local hl = "Directory"
	if entry and entry.is_hidden then
		hl = "FilebufHiddenDir"
	end

	-- Append git status so closed folders still show what happened inside.
	local st = state.get(buf)
	local status_map = st and st.git
	if status_map and entry then
		local segments = git.dir_status(entry, status_map)
		if segments then
			local result = { { text, hl }, { " ", nil } }
			for _, seg in ipairs(segments) do
				result[#result + 1] = { seg.char, seg.hl }
			end
			return result
		end
	end

	return { { text, hl } }
end

----------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------

--- Nearest ancestor directory of `entry` by walking the buffer upward.
---@param buf   number
---@param entry table
---@return table|nil
local function find_parent_dir(buf, entry)
	if not entry or not entry.lnum or not entry.indent then
		return nil
	end
	local want = entry.indent - 1
	if want < 0 then
		return nil
	end
	for i = entry.lnum - 1, 1, -1 do
		local line = (vim.api.nvim_buf_get_lines(buf, i - 1, i, false))[1]
		local _, type_, indent = read_line(line)
		if indent == want and type_ == "dir" then
			return state.resolve_entry(buf, i)
		end
	end
	return nil
end

--- Resolve a foldable directory from an arbitrary entry: if `entry` is already
--- a directory, return it; otherwise walk up to the nearest parent dir.
---@param buf   number
---@param entry table
---@return table|nil
local function resolve_dir_entry(buf, entry)
	if not entry then
		return nil
	end
	if entry.type == "dir" then
		return entry
	end
	return find_parent_dir(buf, entry)
end


----------------------------------------------------------------------
-- Reveal (load the ancestor chain of a path)
----------------------------------------------------------------------

--- Open the folds of every ancestor directory of `path`.
local function open_ancestor_folds(buf, st, path)
	local rel = path:sub(#st.root + 2)
	local prefix = st.root
	local open = M.open_set(st.root)
	for component in rel:gmatch("([^/]+)/") do
		prefix = prefix .. "/" .. component
		local lnum = state.lnum_of(buf, prefix)
		if lnum then
			vim.cmd(string.format("silent! %dfoldopen", lnum))
			open[prefix] = true
		end
	end
end

--- Load and open every ancestor directory of the given paths so each target
--- becomes a visible buffer line.  Expands truncated ancestors on the way
--- (one level at a time) and opens their folds.
---@param buf   number
---@param paths string[]
---@return table[]  the entries that resolved
function M.reveal_paths(buf, paths)
	prof.start("reveal_paths")
	local st = state.get(buf)
	if not st then
		prof.stop()
		return {}
	end

	-- Find each target and open ancestor folds.
	local found = {}
	for _, path in ipairs(paths) do
		if vim.startswith(path, st.root .. "/") then
			open_ancestor_folds(buf, st, path)
			local entry = state.entry_of(buf, path)
			if entry then
				found[#found + 1] = entry
			end
		end
	end

	prof.stop()
	return found
end

--- Reveal a single path.  Returns its entry, or nil when the target is
--- outside the root, does not exist, or is filtered out.
---@param buf         number
---@param target_path string  absolute path under the filebuf root
---@return table|nil
function M.reveal_path(buf, target_path)
	if not target_path then
		return nil
	end
	return M.reveal_paths(buf, { target_path })[1]
end

----------------------------------------------------------------------
-- Fold actions
----------------------------------------------------------------------

--- Record what a fold command issued at `entry` actually did.
---
--- `zo`/`zc` act on the fold at the cursor, which is not always the
--- directory's own: closing a directory that has no fold of its own (no
--- children on screen) closes its parent instead.  One foldclosed() call
--- says which fold moved, and resolving that line names it.
---@param buf   number
---@param entry table
local function sync_fold_at(buf, entry)
	local root = state.root(buf)
	if not root then
		return
	end

	local start = vim.fn.foldclosed(entry.lnum)
	if start == -1 then
		M.mark_open(root, entry.path, true)
	elseif start == entry.lnum then
		M.mark_open(root, entry.path, false)
	else
		-- An enclosing fold closed instead; name it and record that.
		local closed = state.resolve_entry(buf, start)
		M.mark_open(root, closed and closed.path, false)
	end
end

--- Open a fold at `entry`.
---@param buf   number
---@param entry table
function M.fold_open(buf, entry)
	entry = resolve_dir_entry(buf, entry)
	if not entry then
		return
	end

	vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
	vim.cmd("normal! zo")
	sync_fold_at(buf, entry)
end

--- Close a fold at `entry` and persist fold state.
---@param buf   number
---@param entry table
function M.fold_close(buf, entry)
	entry = resolve_dir_entry(buf, entry)
	if not entry then
		return
	end

	vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
	vim.cmd("normal! zc")
	sync_fold_at(buf, entry)
end

--- Toggle a fold at `entry`.
---@param buf   number
---@param entry table
function M.fold_toggle(buf, entry)
	entry = resolve_dir_entry(buf, entry)
	if not entry then
		return
	end

	vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
	local is_closed = vim.fn.foldclosedend(entry.lnum) ~= -1
	vim.cmd(is_closed and "normal! zo" or "normal! zc")
	sync_fold_at(buf, entry)
end

--- Recursively open folds at `entry` (zO).
---@param buf   number
---@param entry table
function M.fold_open_recursive(buf, entry)
	entry = resolve_dir_entry(buf, entry)
	if not entry then
		return
	end
	vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
	vim.cmd("normal! zO")
	mark_subtree_open(buf, entry)
end

--- Open all folds (zR).
---@param buf number
function M.fold_open_all(buf)
	vim.cmd("normal! zR")
	mark_subtree_open(buf, nil)
end

--- Close all folds (zM) and persist state.
---@param buf number
function M.fold_close_all(buf)
	vim.cmd("normal! zM")
	local root = state.root(buf)
	if root then
		M.open_folds[root] = {}
	end
end

----------------------------------------------------------------------
-- Entry opening (file / symlink)
----------------------------------------------------------------------

--- Open a file or follow a symlink.  For symlinks that point to
--- directories, open a new filebuf at the target.
---@param buf   number
---@param entry table
function M.open_entry(buf, entry)
	if not entry or entry.type == "dir" then
		return -- use fold actions for directories
	end

	local target = vim.loop.fs_realpath(entry.path) or entry.path
	if entry.type == "link" and vim.fn.isdirectory(target) == 1 then
		-- Symlink → directory: open a new filebuf.
		require("filebuf").open(target)
	elseif vim.fn.filereadable(target) == 1 then
		vim.cmd("edit " .. vim.fn.fnameescape(target))
	else
		vim.notify("Cannot read: " .. entry.path, vim.log.levels.WARN)
	end
end

--- Handle <CR> / open_or_toggle: toggle fold on directories, open files.
--- Returns true if the entry was handled.
---@param buf   number
---@param entry table
---@return boolean
function M.open_or_toggle(buf, entry)
	if not entry then
		return false
	end

	if entry.type == "dir" then
		M.fold_toggle(buf, entry)
	else
		M.open_entry(buf, entry)
	end
	return true
end

--- Return the entry at cursor in the given filebuf buffer.
---@param buf number
---@return table|nil
function M.get_entry_at_cursor(buf)
	return state.entry_at_cursor(buf)
end

--- Preview a file entry in a floating window (like LSP hover).
--- Bound to K by default.
---@param buf   number
---@param entry table
function M.preview_entry(buf, entry)
	require("filebuf.preview").show(buf, entry)
end

return M
