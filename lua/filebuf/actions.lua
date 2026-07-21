----------------------------------------------------------------------
-- Public API for fold / lazy-expand / entry-open operations.
--
-- Every function takes `buf` (the filebuf buffer number) plus an
-- `entry` table when applicable.  None of them read cursor position
-- internally — the caller resolves the cursor to an entry first so
-- the functions can be called from arbitrary keymaps or scripts.
----------------------------------------------------------------------
local prof = require("filebuf.profiler")
local buffer = require("filebuf.buffer")
local scan = require("filebuf.scan")
local line_mod = require("filebuf.line")
local git = require("filebuf.git")

local M = {}

--- Persisted fold-closed state, keyed by root directory.  Each value is a
--- set of paths whose folds were closed; survives buffer close/reopen so
--- the user's fold preferences stick.
M.closed = {}

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
	entries = entries or buffer.parse_buffer(buf)
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
---@param entries? table[]  pre-parsed display entries (each carrying lnum)
function M.save_fold_state(buf, root, entries)
	M.closed[root] = {}
	entries = entries or vim.b[buf].filebuf_display_entries or {}
	for _, e in ipairs(entries) do
		if e.type == "dir" and vim.fn.foldclosed(e.lnum) ~= -1 then
			M.closed[root][e.path] = true
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
	local entries = vim.b[buf].filebuf_display_entries
	local entry = entries[vim.v.foldstart]
	local text = string.rep(" ", vim.fn.strdisplaywidth(indent_ws)) .. name
	local hl = "Directory"
	if entry and (entry.is_hidden or entry.is_ignored) then
		hl = "FilebufHiddenDir"
	end

	-- Append git status so closed folders still show what happened inside.
	local status_map = vim.b[buf].filebuf_git_status
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

--- Find the index of an entry in a list (reference equality first, then
--- path-match fallback because display and all_entries may hold different
--- objects after a re-scan).
---@param entries table[]
---@param target  table
---@return number|nil
local function find_entry_index(entries, target)
	for i, e in ipairs(entries) do
		if e == target then
			return i
		end
	end
	for i, e in ipairs(entries) do
		if e.path == target.path then
			return i
		end
	end
	return nil
end

--- Snapshot which directories are currently open (fold not closed).
---@param entries table[]
---@return table  set of open dir paths
local function open_dirs_of(entries)
	local open = {}
	for _, e in ipairs(entries) do
		if e.type == "dir" and vim.fn.foldclosed(e.lnum) == -1 then
			open[e.path] = true
		end
	end
	return open
end

--- Return the display entry at the cursor, or nil.
---@param buf number
---@return table|nil
local function entry_at_cursor(buf)
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local entries = vim.b[buf].filebuf_display_entries
	return entries and entries[lnum]
end

--- Check whether a lazy directory has already been expanded.
---@param buf number
---@param entry table
local function is_expanded(buf, entry)
	local expanded = vim.b[buf].filebuf_lazy_expanded or {}
	return not entry.lazy or expanded[entry.path]
end

----------------------------------------------------------------------
-- Fold rebuild (zE + create_folds + restore open dirs)
----------------------------------------------------------------------

--- Destroy all folds, recreate them from the entry list, then re-open
--- every directory whose path is in `open_dirs`.
---@param buf       number
---@param entries   table[]  display entries (1:1 with buffer lines)
---@param open_dirs table    set of dir paths to keep open
function M.rebuild_folds(buf, entries, open_dirs)
	vim.cmd("silent! normal! zE")
	M.create_folds(buf, entries)
	for _, e in ipairs(entries) do
		if e.type == "dir" and open_dirs and open_dirs[e.path] then
			vim.cmd(string.format("silent! %dfoldopen", e.lnum))
		end
	end
end

----------------------------------------------------------------------
-- Lazy expansion
----------------------------------------------------------------------

--- Expand a lazy directory: scan its immediate children, insert them
--- into the buffer and both entry caches, rebuild folds, and restore
--- previously-open directories (plus the newly-expanded one).
--- Idempotent — if the entry is already expanded, this is a no-op.
---@param buf        number
---@param lazy_entry table  the lazy directory entry
function M.expand_dir(buf, lazy_entry)
	-- Idempotency guard: mark expanded BEFORE doing any work so a
	-- failure mid-way cannot lead to double-expansion.
	local expanded = vim.b[buf].filebuf_lazy_expanded
	if not expanded then
		expanded = {}
		vim.b[buf].filebuf_lazy_expanded = expanded
	end
	if not lazy_entry.lazy or expanded[lazy_entry.path] then
		return -- already expanded
	end
	expanded[lazy_entry.path] = true
	vim.b[buf].filebuf_lazy_expanded = expanded

	-- vim.b returns a snapshot — always re-read after writing back.
	local display = vim.b[buf].filebuf_display_entries
	local all_entries = vim.b[buf].filebuf_all_entries
	local by_parent = vim.b[buf].filebuf_by_parent

	-- 1. Scan immediate children.
	local children = scan.scan_dir_children(lazy_entry.path, by_parent)

	-- 2. Set indent (parent indent + 1) and inherit hidden/ignored flags.
	local parent_indent = lazy_entry.indent
	for _, child in ipairs(children) do
		child.indent = parent_indent + 1
		if lazy_entry.is_hidden then
			child.is_hidden = true
		end
		if lazy_entry.is_ignored then
			child.is_ignored = true
		end
	end

	-- 3. Splice children into filebuf_all_entries (diff baseline).
	local all_pos = find_entry_index(all_entries, lazy_entry)
	if all_pos then
		for i = #children, 1, -1 do
			table.insert(all_entries, all_pos + 1, children[i])
		end
		vim.b[buf].filebuf_all_entries = all_entries
	end

	-- 4. Snapshot which dirs are open BEFORE modifying anything.
	local open_dirs = open_dirs_of(display)
	open_dirs[lazy_entry.path] = true -- ensure the expanded dir ends up open

	-- 5. Destroy existing folds BEFORE inserting lines.
	vim.cmd("silent! normal! zE")

	-- 6. Insert only visible children into display entries + buffer text.
	local visible_children = scan.filter_visible(children)
	local child_lines = {}
	for i, child in ipairs(visible_children) do
		child_lines[i] = line_mod.format_line(child)
	end

	if #child_lines > 0 then
		local insert_lnum = lazy_entry.lnum -- insert after the parent line
		vim.api.nvim_buf_set_lines(buf, insert_lnum, insert_lnum, false, child_lines)

		for i = #visible_children, 1, -1 do
			table.insert(display, insert_lnum + 1, visible_children[i])
		end
	end

	-- 7. Re-stamp lnum on all display entries.
	for i = 1, #display do
		display[i].lnum = i
	end

	-- 8. Clear lazy flag on every reference to this entry.
	lazy_entry.lazy = nil
	for _, e in ipairs(all_entries) do
		if e.path == lazy_entry.path then
			e.lazy = nil
		end
	end
	vim.b[buf].filebuf_display_entries = display
	vim.b[buf].filebuf_all_entries = all_entries

	-- 9. Rebuild folds and restore previously-open directories.
	M.create_folds(buf, display)
	for _, e in ipairs(display) do
		if e.type == "dir" and open_dirs[e.path] then
			vim.cmd(string.format("silent! %dfoldopen", e.lnum))
		end
	end

	-- Buffer modified tracking: expanding a lazy dir changes the display
	-- but not the disk — it is not a user edit.
	vim.bo[buf].modified = false
end

--- Recursively expand a lazy directory and all nested lazy dirs within it.
---@param buf        number
---@param lazy_entry table
function M.expand_dir_recursive(buf, lazy_entry)
	if not lazy_entry.lazy then
		return -- already expanded
	end
	M.expand_dir(buf, lazy_entry)
	-- Collect lazy child paths first (expansion shifts indices).
	local display = vim.b[buf].filebuf_display_entries
	local start = lazy_entry.lnum
	local finish = #display
	for i = start + 1, #display do
		if display[i].indent <= lazy_entry.indent then
			finish = i - 1
			break
		end
	end
	local lazy_paths = {}
	local expanded = vim.b[buf].filebuf_lazy_expanded or {}
	for i = start + 1, finish do
		if display[i].lazy and not expanded[display[i].path] then
			lazy_paths[#lazy_paths + 1] = display[i].path
		end
	end
	for _, path in ipairs(lazy_paths) do
		display = vim.b[buf].filebuf_display_entries
		expanded = vim.b[buf].filebuf_lazy_expanded or {}
		for _, e in ipairs(display) do
			if e.path == path and e.lazy and not expanded[e.path] then
				M.expand_dir_recursive(buf, e)
				break
			end
		end
	end
end

--- Expand all lazy directories in the buffer (without opening any folds).
---@param buf number
function M.expand_all_dirs(buf)
	local entries = vim.b[buf].filebuf_display_entries
	if not entries then
		return
	end

	-- Collect lazy paths first; expanding mutates the list.
	local lazy_paths = {}
	for _, e in ipairs(entries) do
		if e.lazy and not is_expanded(buf, e) then
			lazy_paths[#lazy_paths + 1] = e.path
		end
	end
	for _, path in ipairs(lazy_paths) do
		for _, e in ipairs(vim.b[buf].filebuf_display_entries or {}) do
			if e.path == path and e.lazy and not is_expanded(buf, e) then
				M.expand_dir(buf, e)
				break
			end
		end
	end
end

----------------------------------------------------------------------
-- Fold actions
----------------------------------------------------------------------

--- Open a fold at `entry`.  If the entry is a lazy unexpanded directory,
--- expand it first (which also opens the fold).
---@param buf   number
---@param entry table
function M.fold_open(buf, entry)
	if entry.type ~= "dir" then
		return
	end

	if entry.lazy and not is_expanded(buf, entry) then
		M.expand_dir(buf, entry)
		return
	end

	vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
	vim.cmd("normal! zo")
	M.save_fold_state(buf, vim.b[buf].filebuf_root)
end

--- Close a fold at `entry` and persist fold state.
---@param buf   number
---@param entry table
function M.fold_close(buf, entry)
	if entry.type ~= "dir" then
		return
	end

	vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
	vim.cmd("normal! zc")
	M.save_fold_state(buf, vim.b[buf].filebuf_root)
end

--- Toggle a fold at `entry`.  Expands lazy dirs before toggling.
---@param buf   number
---@param entry table
function M.fold_toggle(buf, entry)
	if entry.type ~= "dir" then
		return
	end

	if entry.lazy and not is_expanded(buf, entry) then
		M.expand_dir(buf, entry)
		return
	end

	vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
	local is_closed = vim.fn.foldclosedend(entry.lnum) ~= -1
	vim.cmd(is_closed and "normal! zo" or "normal! zc")
	M.save_fold_state(buf, vim.b[buf].filebuf_root)
end

--- Recursively open folds at `entry` (zO).  Expands lazy dirs recursively first.
---@param buf   number
---@param entry table
function M.fold_open_recursive(buf, entry)
	if entry.type ~= "dir" then
		return
	end

	if entry.lazy and not is_expanded(buf, entry) then
		M.expand_dir_recursive(buf, entry)
		return
	end

	vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
	vim.cmd("normal! zO")
	M.save_fold_state(buf, vim.b[buf].filebuf_root)
end

--- Open all folds (zR).  Expands all lazy dirs first, then opens all folds.
---@param buf number
function M.fold_open_all(buf)
	M.expand_all_dirs(buf)
	vim.cmd("normal! zR")
	M.save_fold_state(buf, vim.b[buf].filebuf_root)
end

--- Close all folds (zM) and persist state.
---@param buf number
function M.fold_close_all(buf)
	vim.cmd("normal! zM")
	M.save_fold_state(buf, vim.b[buf].filebuf_root)
end

----------------------------------------------------------------------
-- Entry opening (file / symlink)
----------------------------------------------------------------------

--- Open a file or follow a symlink.  For symlinks that point to
--- directories, open a new filebuf at the target.
---@param buf   number
---@param entry table
function M.open_entry(buf, entry)
	if entry.type == "dir" then
		return -- use fold actions for directories
	end

	local target = vim.loop.fs_realpath(entry.path) or entry.path
	if entry.type == "link" and vim.fn.isdirectory(target) == 1 then
		-- Symlink → directory: open a new filebuf.
		local filebuf = require("filebuf")
		filebuf.open(target)
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
		return true
	else
		M.open_entry(buf, entry)
		return true
	end
end

----------------------------------------------------------------------
-- Cursor-resolution convenience
----------------------------------------------------------------------

--- Return the entry at cursor in the given filebuf buffer.
--- Convenience wrapper so callers don't need to inline the lookup.
---@param buf number
---@return table|nil
function M.get_entry_at_cursor(buf)
	return entry_at_cursor(buf)
end

return M
