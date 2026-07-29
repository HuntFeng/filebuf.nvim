----------------------------------------------------------------------
-- Public API for fold / lazy-expand / entry-open operations.
--
-- Every function takes `buf` (the filebuf buffer number) plus an
-- `entry` table when applicable.  None of them read cursor position
-- internally — the caller resolves the cursor to an entry first so
-- the functions can be called from arbitrary keymaps or scripts.
--
-- Fold creation works by scanning buffer text directly (O(n) stack
-- pass); there is no in-memory index to consult.
----------------------------------------------------------------------
local prof = require("filebuf.profiler")
local config = require("filebuf.config")
local scan = require("filebuf.scan")
local state = require("filebuf.state")
local line_mod = require("filebuf.line")
local buffer = require("filebuf.buffer")
local git = require("filebuf.git")

local M = {}

--- Persisted fold-closed state, keyed by root directory.  Each value is a
--- set of paths whose folds were closed; survives buffer close/reopen so
--- the user's fold preferences stick.
M.closed = {}

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
-- Fold creation from buffer text
----------------------------------------------------------------------

--- Create a fold spanning each directory and its descendants by scanning
--- buffer text.  Single O(n) stack pass: dirs are pushed when seen and
--- their folds emitted when an entry at ≤ indent arrives.  LIFO order
--- emits inner folds before outer ones, as Neovim requires.
---@param buf number
function M.create_folds_from_buffer(buf)
	prof.start("create_folds")
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	if #lines == 0 then
		prof.stop()
		return
	end

	-- Clear any existing folds so stale ranges from a previous render
	-- never interfere.  Must happen before any :fold commands are issued.
	vim.cmd("silent! normal! zE")

	local stack = {} -- { lnum, indent }
	local prev_lnum = nil
	local prev_indent = nil
	local cmds = {}

	for lnum, line in ipairs(lines) do
		local name, type_, indent = read_line(line)
		if name then
			-- Pop directories whose subtree has ended.
			while #stack > 0 and stack[#stack].indent >= indent do
				local d = table.remove(stack)
				if prev_lnum and prev_indent > d.indent and prev_lnum > d.lnum then
					cmds[#cmds + 1] = string.format("%d,%dfold", d.lnum, prev_lnum)
				end
			end

			if type_ == "dir" then
				stack[#stack + 1] = { lnum = lnum, indent = indent }
			end

			prev_lnum = lnum
			prev_indent = indent
		end
	end

	-- Close any remaining dirs on the stack.
	while #stack > 0 do
		local d = table.remove(stack)
		if prev_lnum and prev_indent > d.indent and prev_lnum > d.lnum then
			cmds[#cmds + 1] = string.format("%d,%dfold", d.lnum, prev_lnum)
		end
	end

	if #cmds > 0 then
		vim.cmd(table.concat(cmds, "|"))
	end
	prof.stop()
end

----------------------------------------------------------------------
-- Fold rebuild & open (for find-mode and full-tree renders)
----------------------------------------------------------------------

--- Destroy all folds, recreate them from an entry list (find mode), then
--- re-open the directories `open_dirs` selects.
---
--- `open_dirs` is either a set of paths to open or a predicate on the path.
---@param buf       number
---@param entries   table[]  rendered entries (1:1 with buffer lines)
---@param open_dirs table|fun(path: string): boolean|nil
function M.rebuild_folds(buf, entries, open_dirs)
	vim.cmd("silent! normal! zE")
	-- Use the entry-list path for find mode (those entries are in memory).
	local stack = {}
	local prev
	local cmds = {}

	for _, e in ipairs(entries) do
		while #stack > 0 and stack[#stack].indent >= e.indent do
			local d = table.remove(stack)
			if prev and prev.indent > d.indent and prev.lnum > d.lnum then
				cmds[#cmds + 1] = string.format("%d,%dfold", d.lnum, prev.lnum)
			end
		end
		if e.type == "dir" then
			stack[#stack + 1] = { lnum = e.lnum, indent = e.indent }
		end
		prev = e
	end
	while #stack > 0 do
		local d = table.remove(stack)
		if prev and prev.indent > d.indent and prev.lnum > d.lnum then
			cmds[#cmds + 1] = string.format("%d,%dfold", d.lnum, prev.lnum)
		end
	end

	if #cmds > 0 then
		vim.cmd(table.concat(cmds, "|"))
	end

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

--- Open folds for the directories in `open_dirs`.  Scans buffer text once
--- to build paths and check fold status.
---@param buf       number
---@param open_dirs table|fun(path: string): boolean
function M.open_folds(buf, open_dirs)
	if not open_dirs then
		return
	end
	local st = state.get(buf)
	if not st then
		return
	end

	local is_open = type(open_dirs) == "function" and open_dirs or function(path)
		return open_dirs[path]
	end

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local stack = {}

	for lnum, line in ipairs(lines) do
		local name, type_, indent = read_line(line)
		if name then
			while #stack > 0 and stack[#stack].indent >= indent do
				table.remove(stack)
			end
			local parent = #stack > 0 and stack[#stack].path or st.root
			local path = parent .. "/" .. name
			if type_ == "dir" then
				stack[#stack + 1] = { indent = indent, path = path }
				if is_open(path) then
					vim.cmd(string.format("silent! %dfoldopen", lnum))
				end
			end
		end
	end
end

----------------------------------------------------------------------
-- Fold state persistence
----------------------------------------------------------------------

--- Persist the closed-fold set for `root` from the current buffer.
--- When `entries` is provided (find mode) they are used for path
--- resolution; otherwise paths are built by scanning the buffer.
---@param buf     number
---@param root    string
---@param entries table[]|nil  pre-rendered entries (each carrying lnum)
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

	-- No entry list: scan buffer text and build paths.
	local st = state.get(buf)
	if not st then
		return
	end
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local stack = {}

	for lnum, line in ipairs(lines) do
		local name, type_, indent = read_line(line)
		if name then
			while #stack > 0 and stack[#stack].indent >= indent do
				table.remove(stack)
			end
			local parent = #stack > 0 and stack[#stack].path or root
			local path = parent .. "/" .. name
			if type_ == "dir" then
				stack[#stack + 1] = { indent = indent, path = path }
				if vim.fn.foldclosed(lnum) ~= -1 then
					closed[path] = true
				end
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
-- Lazy expansion
----------------------------------------------------------------------

--- Expand a truncated directory: scan its children, insert them into
--- the buffer after the directory line, and rebuild folds.
--- Idempotent — if the entry is already expanded, this is a no-op.
---@param buf   number
---@param entry table  the lazy directory entry
---@return number  how many entries were gained (0 when already expanded)
function M.expand_dir(buf, entry)
	local st = state.get(buf)
	if not st or not entry or entry.type ~= "dir" or not entry.lazy then
		return 0
	end

	-- Get one level of children.
	local children = scan.scan_dir_children(entry.path, st.root)
	if #children == 0 then
		-- Empty dir — remove from truncated set so we don't try again.
		st.truncated_dirs[entry.path] = nil
		return 0
	end

	-- Remove from truncated set.
	st.truncated_dirs[entry.path] = nil

	-- Format children as buffer lines.
	local child_indent = entry.indent + 1
	local child_lines = {}
	for _, child in ipairs(children) do
		local suffix = child.type == "dir" and "/" or (child.type == "link" and "@" or "")
		local name = child.name
		if name:find("[\n\r\t]") then
			name = name:gsub("[\n\r\t]", { ["\n"] = "$'\\n'", ["\r"] = "$'\\r'", ["\t"] = "$'\\t'" })
		end
		child_lines[#child_lines + 1] = line_mod.indent_str(child_indent) .. name .. suffix
		-- Mark children that are dirs as truncated (they're at least as deep as
		-- the parent was, and we haven't loaded their children).
		if child.type == "dir" then
			st.truncated_dirs[child.path] = true
		end
	end

	-- Find insertion point: after the directory entry, before the next
	-- sibling at the same or lesser indent level.
	local insert_at = entry.lnum
	local total = vim.api.nvim_buf_line_count(buf)
	while insert_at < total do
		local next_line = (vim.api.nvim_buf_get_lines(buf, insert_at, insert_at + 1, false))[1]
		local _, _, next_indent = read_line(next_line)
		if next_indent and next_indent <= entry.indent then
			break
		end
		insert_at = insert_at + 1
	end

	-- Insert lines (insert_at is 0-indexed for nvim_buf_set_lines).
	buffer.without_undo(buf, function()
		vim.api.nvim_buf_set_lines(buf, insert_at, insert_at, false, child_lines)
	end)

	-- Rebuild all folds and mark path cache dirty.
	M.create_folds_from_buffer(buf)

	-- Open the fold for the newly expanded dir.
	vim.cmd(string.format("silent! %dfoldopen", entry.lnum))
	M.save_fold_state(buf, st.root)

	return #child_lines
end

--- Recursively expand a directory and every nested directory within it.
---@param buf   number
---@param entry table
function M.expand_dir_recursive(buf, entry)
	local st = state.get(buf)
	if not st or not entry or entry.type ~= "dir" then
		return
	end

	if not entry.lazy then
		-- Already loaded — just open the folds below it.
		vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
		vim.cmd("normal! zO")
		M.save_fold_state(buf, st.root)
		return
	end

	-- Expand level by level.  scan_dir_children is fast (one fs_scandir),
	-- and we insert after the parent line.
	local pending = { { parent_lnum = entry.lnum, parent_indent = entry.indent, dir = entry.path } }
	local total_inserted = 0
	local max_entries = config.max_expand_entries

	while #pending > 0 and total_inserted < max_entries do
		local item = table.remove(pending)
		st.truncated_dirs[item.dir] = nil

		local children = scan.scan_dir_children(item.dir, st.root)
		if #children > 0 then
			local child_indent = item.parent_indent + 1
			local child_lines = {}
			for _, child in ipairs(children) do
				local suffix = child.type == "dir" and "/" or (child.type == "link" and "@" or "")
				local name = child.name
				if name:find("[\n\r\t]") then
					name = name:gsub("[\n\r\t]", { ["\n"] = "$'\\n'", ["\r"] = "$'\\r'", ["\t"] = "$'\\t'" })
				end
				child_lines[#child_lines + 1] = line_mod.indent_str(child_indent) .. name .. suffix
				total_inserted = total_inserted + 1
				if child.type == "dir" then
					pending[#pending + 1] = {
						parent_lnum = item.parent_lnum + #child_lines,
						parent_indent = child_indent,
						dir = child.path,
					}
				end
				if total_inserted >= max_entries then
					break
				end
			end

			-- Find insertion point.
			local insert_at = item.parent_lnum
			local total = vim.api.nvim_buf_line_count(buf)
			while insert_at < total do
				local next_line = (vim.api.nvim_buf_get_lines(buf, insert_at, insert_at + 1, false))[1]
				local _, _, next_indent = read_line(next_line)
				if next_indent and next_indent <= item.parent_indent then
					break
				end
				insert_at = insert_at + 1
			end

			buffer.without_undo(buf, function()
				vim.api.nvim_buf_set_lines(buf, insert_at, insert_at, false, child_lines)
			end)
		end
	end

	M.create_folds_from_buffer(buf)

	if total_inserted >= max_entries then
		vim.notify(
			string.format(
				"filebuf: stopped after loading %d entries (max_expand_entries); expand deeper folders individually",
				max_entries
			),
			vim.log.levels.WARN
		)
	end
end

--- Expand every truncated directory currently on screen (one level each).
---@param buf number
function M.expand_all_dirs(buf)
	local st = state.get(buf)
	if not st then
		return
	end

	-- Collect truncated dir entries by scanning the buffer.
	local to_expand = {}
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local stack = {}

	for lnum, line in ipairs(lines) do
		local name, type_, indent = read_line(line)
		if name then
			while #stack > 0 and stack[#stack].indent >= indent do
				table.remove(stack)
			end
			local parent = #stack > 0 and stack[#stack].path or st.root
			local path = parent .. "/" .. name
			if type_ == "dir" then
				stack[#stack + 1] = { indent = indent, path = path }
				if st.truncated_dirs[path] then
					to_expand[#to_expand + 1] = state.resolve_entry(buf, lnum)
				end
			end
		end
	end

	for _, e in ipairs(to_expand) do
		M.expand_dir(buf, e)
	end
end

----------------------------------------------------------------------
-- Reveal (load the ancestor chain of a path)
----------------------------------------------------------------------

--- Mark every ancestor directory of `path` as needing expansion.
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
		if st.truncated_dirs[prefix] then
			st.truncated_dirs[prefix] = nil
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

	-- Expand truncated ancestors.
	local changed = false
	for _, path in ipairs(paths) do
		if mark_ancestors(st, path) then
			changed = true
		end
	end

	-- When ancestors were expanded we need to re-render.
	if changed then
		render().tree(buf, { keep_view = true, open_dirs = state.open_dirs(buf) })
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
	M.save_fold_state(buf, st.root)

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

--- Open a fold at `entry`.  If the entry is a truncated unexpanded
--- directory, expand it first (which also opens the fold).
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

--- Toggle a fold at `entry`.  Expands truncated dirs before toggling.
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

--- Recursively open folds at `entry` (zO).  Expands truncated dirs
--- recursively first.
---@param buf   number
---@param entry table
function M.fold_open_recursive(buf, entry)
	entry = resolve_dir_entry(buf, entry)
	if not entry then
		return
	end
	M.expand_dir_recursive(buf, entry)
end

--- Open all folds (zR).  Expands all truncated dirs first.
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
