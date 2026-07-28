----------------------------------------------------------------------
-- Public API for fold / lazy-expand / entry-open operations.
--
-- Every function takes `buf` (the filebuf buffer number) plus an
-- `entry` table when applicable.  None of them read cursor position
-- internally — the caller resolves the cursor to an entry first so
-- the functions can be called from arbitrary keymaps or scripts.
--
-- Expansion works by recording a directory in state.expanded and re-rendering.
-- Nothing here splices buffer lines or renumbers entries: the render is the
-- single writer, and the index it installs is the single reader.
----------------------------------------------------------------------
local prof = require("filebuf.profiler")
local config = require("filebuf.config")
local scan = require("filebuf.scan")
local state = require("filebuf.state")
local git = require("filebuf.git")

local M = {}

--- Persisted fold-closed state, keyed by root directory.  Each value is a
--- set of paths whose folds were closed; survives buffer close/reopen so
--- the user's fold preferences stick.
M.closed = {}

--- Required lazily: render needs actions for fold rebuilding.
local function render()
	return require("filebuf.render")
end

----------------------------------------------------------------------
-- Fold creation & persistence (internal machinery)
----------------------------------------------------------------------

--- Create a fold spanning each directory and its descendants (nested dirs get
--- their own inner folds).  Single O(n) stack pass: directories are pushed
--- when seen and their fold emitted when an entry at ≤ indent arrives.  The
--- LIFO order emits inner folds before outer ones, as Neovim requires.
---@param buf number
---@param entries? table[]  pre-parsed entries (avoids a redundant parse)
function M.create_folds(buf, entries)
	prof.start("create_folds")
	entries = entries or state.entries(buf)
	if #entries == 0 then
		prof.stop()
		return
	end

	local stack = {} -- { lnum, indent }
	local prev -- last entry seen (fold endpoint)
	local cmds = {}

	local function close_dir(d)
		if prev and prev.indent > d.indent and prev.lnum > d.lnum then
			cmds[#cmds + 1] = string.format("%d,%dfold", d.lnum, prev.lnum)
		end
	end

	for _, e in ipairs(entries) do
		-- Pop directories whose subtree has ended (current indent back at or
		-- above theirs); prev is that subtree's last line.
		while #stack > 0 and stack[#stack].indent >= e.indent do
			close_dir(table.remove(stack))
		end
		if e.type == "dir" then
			stack[#stack + 1] = { lnum = e.lnum, indent = e.indent }
		end
		prev = e
	end
	while #stack > 0 do
		close_dir(table.remove(stack))
	end

	if #cmds > 0 then
		vim.cmd(table.concat(cmds, "|"))
	end
	prof.stop()
end

--- Persist the closed-fold set for `root` from the current buffer.
---@param buf number
---@param root string
---@param entries? table[]  pre-rendered entries (each carrying lnum)
function M.save_fold_state(buf, root, entries)
	if not root then
		return
	end
	local closed = {}
	M.closed[root] = closed

	if entries then
		for _, e in ipairs(entries) do
			if e.type == "dir" and vim.fn.foldclosed(e.lnum) ~= -1 then
				closed[e.path] = true
			end
		end
		return
	end

	-- No entry list: read directory lines straight off the index instead of
	-- materializing an entry table per line.
	local st = state.get(buf)
	if not st then
		return
	end
	for lnum = 1, st.count do
		if st.types[lnum] == "dir" and vim.fn.foldclosed(lnum) ~= -1 then
			closed[st.paths[lnum]] = true
		end
	end
end

--- Fold-text callback (v:lua.FilebufFoldText).  Shows the entry name with
--- its indent converted to spaces so it aligns regardless of tabstop.
--- When the directory has git status (aggregated from descendants), the
--- status chars are appended with per-char highlighting.
function _G.FilebufFoldText()
	local line = vim.fn.getline(vim.v.foldstart)
	local indent_ws = line:match("^(%s*)") or ""
	local name = line:match("^%s*(.-)%s*$") or line
	local buf = vim.api.nvim_get_current_buf()
	local entry = state.entry(buf, vim.v.foldstart)
	local text = string.rep(" ", vim.fn.strdisplaywidth(indent_ws)) .. name
	local hl = "Directory"
	if entry and (entry.is_hidden or entry.is_ignored) then
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

--- Nearest ancestor directory of `entry`.
---
--- Scans the indent array backward rather than materializing an entry per line,
--- and stops at the first line one level shallower — so this stays cheap even
--- with a six-figure tree on screen.
---@param buf   number
---@param entry table
---@return table|nil
local function find_parent_dir(buf, entry)
	local st = state.get(buf)
	if not st or not entry or not entry.lnum then
		return nil
	end
	local want = (entry.indent or 0) - 1
	if want < 0 then
		return nil
	end
	local from = math.min(entry.lnum - 1, st.valid)
	for lnum = from, 1, -1 do
		if st.indents[lnum] == want and st.types[lnum] == "dir" then
			return state.entry(buf, lnum)
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
-- Fold rebuild (zE + create_folds + restore open dirs)
----------------------------------------------------------------------

--- Destroy all folds, recreate them from the entry list, then re-open the
--- directories `open_dirs` selects.
---
--- `open_dirs` is either a set of paths to open or a predicate on the path.  The
--- predicate form is what lets a fresh open restore persisted fold state, where
--- the saved data is the *closed* set and every unmentioned directory should end
--- up open.
---@param buf       number
---@param entries   table[]  rendered entries (1:1 with buffer lines)
---@param open_dirs table|fun(path: string): boolean|nil  nil = leave all closed
function M.rebuild_folds(buf, entries, open_dirs)
	vim.cmd("silent! normal! zE")
	M.create_folds(buf, entries)
	if not open_dirs then
		return
	end
	local is_open = type(open_dirs) == "function" and open_dirs or function(path)
		return open_dirs[path]
	end
	for _, e in ipairs(entries) do
		if e.type == "dir" and is_open(e.path) then
			vim.cmd(string.format("silent! %dfoldopen", e.lnum))
		end
	end
end

----------------------------------------------------------------------
-- Lazy expansion
----------------------------------------------------------------------

--- Expand a lazy directory: record it as expanded and re-render.
--- Idempotent — if the entry is already expanded, this is a no-op.
---@param buf   number
---@param entry table  the lazy directory entry
---@return number  how many entries the render gained (0 when already expanded)
function M.expand_dir(buf, entry)
	local st = state.get(buf)
	if not st or not entry or entry.type ~= "dir" or not entry.lazy then
		return 0
	end

	st.expanded[entry.path] = true

	local before = st.count
	local open_dirs = state.open_dirs(buf)
	open_dirs[entry.path] = true -- ensure the expanded dir ends up open
	render().tree(buf, { keep_view = true, open_dirs = open_dirs })

	return st.count - before
end

--- Ask before loading a large subtree.  Returns false when the user declines.
---
--- The count is taken up front with a cheap capped walk (no entries built, no
--- buffer lines) so the dialog can state a real number instead of a vague
--- warning.  Skipped entirely when expand_confirm_threshold is falsy.
---@param buf        number
---@param lazy_entry table
---@return boolean  true to proceed
local function confirm_large_expand(buf, lazy_entry)
	local threshold = config.expand_confirm_threshold
	if not threshold or threshold <= 0 then
		return true
	end

	local cap = config.max_expand_entries + 1
	local count, capped = scan.count_subtree(lazy_entry.path, state.root(buf), cap)
	if count < threshold then
		return true
	end

	local how_many = capped and string.format("more than %d", cap - 1) or tostring(count)
	local message =
		string.format("Recursively expanding '%s/' will load %s entries.\nContinue?", lazy_entry.name, how_many)
	-- Default to No: this is the expensive branch.
	return vim.fn.confirm(message, "&Yes\n&No", 2, "Question") == 1
end

--- Recursively expand a lazy directory and every nested directory within it.
---
--- The whole subtree is marked expanded in one walk and rendered once.
--- Expanding level by level would re-render the buffer per level, which on a
--- deep subtree is quadratic for no benefit.
---
--- Two guards apply: the user is asked to confirm once the subtree exceeds
--- config.expand_confirm_threshold entries, and loading stops outright at
--- config.max_expand_entries rather than hanging the editor.
---@param buf   number
---@param entry table
function M.expand_dir_recursive(buf, entry)
	local st = state.get(buf)
	if not st or not entry or entry.type ~= "dir" then
		return
	end

	if not entry.lazy then
		-- Already loaded — just open the folds beneath it.
		vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
		vim.cmd("normal! zO")
		M.save_fold_state(buf, st.root)
		return
	end

	if not confirm_large_expand(buf, entry) then
		vim.notify("filebuf: expand cancelled", vim.log.levels.INFO)
		return
	end

	local left = config.max_expand_entries
	local open_dirs = state.open_dirs(buf)
	local pending = { entry.path }
	while #pending > 0 and left > 0 do
		local dir = table.remove(pending)
		st.expanded[dir] = true
		open_dirs[dir] = true
		for _, child in ipairs(scan.scan_dir_children(dir, st.root)) do
			if config.show_hidden or not (child.is_hidden or child.is_ignored) then
				left = left - 1
				if left <= 0 then
					break
				end
				if child.type == "dir" then
					pending[#pending + 1] = child.path
				end
			end
		end
	end

	render().tree(buf, { keep_view = true, open_dirs = open_dirs })

	if left <= 0 then
		vim.notify(
			string.format(
				"filebuf: stopped after loading %d entries (max_expand_entries); expand deeper folders individually",
				config.max_expand_entries
			),
			vim.log.levels.WARN
		)
	end
end

--- Expand every lazy directory currently on screen (one level per call).
---@param buf number
function M.expand_all_dirs(buf)
	local st = state.get(buf)
	if not st then
		return
	end

	local changed = false
	for lnum = 1, st.count do
		if st.types[lnum] == "dir" then
			local path = st.paths[lnum]
			local below = st.indents[lnum + 1]
			local has_children = below and below > st.indents[lnum]
			if not has_children and not st.expanded[path] then
				st.expanded[path] = true
				changed = true
			end
		end
	end

	if changed then
		render().tree(buf, { keep_view = true })
	end
end

----------------------------------------------------------------------
-- Reveal (load the ancestor chain of a path)
----------------------------------------------------------------------

--- Mark every ancestor directory of `path` as expanded.
---@return boolean changed
local function mark_ancestors(st, path)
	if not vim.startswith(path, st.root .. "/") then
		return false
	end
	local rel = path:sub(#st.root + 2)
	local prefix = st.root
	local changed = false
	for component in rel:gmatch("([^/]+)/") do
		prefix = prefix .. "/" .. component
		if not st.expanded[prefix] then
			st.expanded[prefix] = true
			changed = true
		end
	end
	return changed
end

--- Open the folds of every ancestor directory of `path`.
local function open_ancestor_folds(buf, st, path)
	local rel = path:sub(#st.root + 2)
	local prefix = st.root
	for component in rel:gmatch("([^/]+)/") do
		prefix = prefix .. "/" .. component
		local lnum = state.lnum_of(buf, prefix)
		if lnum then
			vim.cmd(string.format("silent! %dfoldopen", lnum))
		end
	end
end

--- Load and open every ancestor directory of the given paths so each target
--- becomes a visible buffer line.
---
--- Only ancestors are expanded — sibling subdirectories along the way are
--- listed (they are children of an expanded ancestor) but never expanded
--- themselves.  All the ancestors are marked first and the buffer is rendered
--- once, so revealing 500 search hits costs one render, not 500.
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

	local changed = false
	for _, path in ipairs(paths) do
		if mark_ancestors(st, path) then
			changed = true
		end
	end
	if changed then
		render().tree(buf, { keep_view = true, open_dirs = state.open_dirs(buf) })
	end

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
	M.save_fold_state(buf, st.root)

	prof.stop()
	return found
end

--- Reveal a single path.  Returns its entry, or nil when the target is outside
--- the root, does not exist, or is filtered out of the display by show_hidden.
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

--- Open a fold at `entry`.  If the entry is a lazy unexpanded directory,
--- expand it first (which also opens the fold).
---@param buf   number
---@param entry table
function M.fold_open(buf, entry)
	entry = resolve_dir_entry(buf, entry)
	if not entry then
		return
	end

	if entry.lazy then
		M.expand_dir(buf, entry)
		return
	end

	vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
	vim.cmd("normal! zo")
	M.save_fold_state(buf, state.root(buf))
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
	M.save_fold_state(buf, state.root(buf))
end

--- Toggle a fold at `entry`.  Expands lazy dirs before toggling.
---@param buf   number
---@param entry table
function M.fold_toggle(buf, entry)
	entry = resolve_dir_entry(buf, entry)
	if not entry then
		return
	end

	if entry.lazy then
		M.expand_dir(buf, entry)
		return
	end

	vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
	local is_closed = vim.fn.foldclosedend(entry.lnum) ~= -1
	vim.cmd(is_closed and "normal! zo" or "normal! zc")
	M.save_fold_state(buf, state.root(buf))
end

--- Recursively open folds at `entry` (zO).  Expands lazy dirs recursively first.
---@param buf   number
---@param entry table
function M.fold_open_recursive(buf, entry)
	entry = resolve_dir_entry(buf, entry)
	if not entry then
		return
	end
	M.expand_dir_recursive(buf, entry)
end

--- Open all folds (zR).  Expands all lazy dirs first, then opens all folds.
---@param buf number
function M.fold_open_all(buf)
	M.expand_all_dirs(buf)
	vim.cmd("normal! zR")
	M.save_fold_state(buf, state.root(buf))
end

--- Close all folds (zM) and persist state.
---@param buf number
function M.fold_close_all(buf)
	vim.cmd("normal! zM")
	M.save_fold_state(buf, state.root(buf))
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

----------------------------------------------------------------------
-- Cursor-resolution convenience
----------------------------------------------------------------------

--- Return the entry at cursor in the given filebuf buffer.
---@param buf number
---@return table|nil
function M.get_entry_at_cursor(buf)
	return state.entry_at_cursor(buf)
end

--- Preview a file entry in a floating window (like LSP hover).
--- Bound to K by default.  Pressing K again on the same entry focuses
--- the window; pressing K on a different entry replaces the content.
---@param buf   number
---@param entry table
function M.preview_entry(buf, entry)
	require("filebuf.preview").show(buf, entry)
end

return M
