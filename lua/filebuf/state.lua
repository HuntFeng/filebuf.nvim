----------------------------------------------------------------------
-- Per-buffer state.
--
-- The buffer text is the source of truth for the tree: names, types and
-- structure all live in the lines themselves (see filebuf.line).  There
-- is no in-memory index — the absolute path of any line is derived on
-- demand by walking up the buffer to reconstruct the ancestor chain.
--
-- Path resolution is O(depth) which is typically < 20 lines per lookup,
-- and the path→lnum map is built once and cached until the next edit.
--
-- State lives in a module-local table, never in vim.b.
----------------------------------------------------------------------
local line_mod = require("filebuf.line")

local M = {}

--- bufnr → state.  Module-local on purpose; see the header.
local states = {}

--- root → show_hidden, for roots the user has toggled.
---
--- filebuf reuses one buffer, so state is reinitialised on every open; without
--- this a re-open would silently revert the toggle.  Persisting it per root
--- matches how actions.open_folds already remembers fold state, and is keyed
--- by root rather than global so two projects do not fight over it.
local hidden_by_root = {}

--- Forget every remembered per-root preference.  Exists so tests do not
--- inherit each other's toggles; nothing in normal operation calls it.
function M.reset_preferences()
	hidden_by_root = {}
end

--- Remember the show-hidden preference for `root`.
---@param root string
---@param show boolean
function M.set_show_hidden(root, show)
	hidden_by_root[root] = show and true or nil
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

--- Create (or reset) the state for `buf`.
---@param buf  number
---@param root string  absolute root directory, no trailing slash
---@return table state
function M.init(buf, root)
	states[buf] = {
		root = root,

		--- Directories at maxdepth whose children haven't been loaded yet.
		--- When a user expands one, its children are inserted into the buffer
		--- and the path is removed from this set.
		truncated_dirs = {},

		eager = false,
		mode = "normal", -- "normal" | "find"
		git = nil, -- path → status map
		matches = nil, -- path → true (search highlighting)
		rendering = false, -- suppress on_lines bookkeeping mid-render
		attached = false,

		--- The row cache for the last full render (filebuf.snapshot).  Kept
		--- across renders; freed with the state on BufDelete.
		snap = nil,

		--- "Show hidden entries" for this buffer: the remembered preference for
		--- this root, else the configured default.  Owned here rather than in
		--- config, which toggle_hidden used to mutate globally -- that affected
		--- every other filebuf and leaked into filebuf.search's fd arguments.
		show_hidden = hidden_by_root[root] or (require("filebuf.config").show_hidden and true or false),

		--- Whether the buffer still matches snap.view line for line.  While
		--- true, path resolution and fold levels are answered from the
		--- snapshot; once an edit lands it goes false and every lookup falls
		--- back to walking the buffer, which is always correct.
		snap_clean = false,

		--- Range of lines touched since the last render, for the incremental
		--- re-parse on :w.  nil means "nothing edited".
		dirty_lo = nil,
		dirty_hi = nil,

		-- Transient path→lnum cache, built on first use, cleared on edit.
		_by_path = nil,
		_by_path_dirty = true,
	}
	return states[buf]
end

---@param buf number
---@return table|nil
function M.get(buf)
	return states[buf]
end

--- Root directory of `buf`, or nil when it isn't a filebuf.
---@param buf number
---@return string|nil
function M.root(buf)
	local st = states[buf]
	return st and st.root
end

--- Whether `buf` is a live filebuf buffer.
---@param buf number
---@return boolean
function M.is_filebuf(buf)
	return states[buf] ~= nil
end

--- Drop all state for `buf`.
---@param buf number
function M.clear(buf)
	states[buf] = nil
end

--- Every live filebuf buffer number.
---@return number[]
function M.buffers()
	local out = {}
	for buf in pairs(states) do
		out[#out + 1] = buf
	end
	return out
end

----------------------------------------------------------------------
-- Edit tracking
----------------------------------------------------------------------

--- Watch `buf` for edits so the path→lnum cache knows when to rebuild.
--- Unlike the old index with its watermark, edits simply mark the cache
--- dirty — the next path lookup rebuilds it in one pass.
---@param buf number
function M.attach(buf)
	local st = states[buf]
	if not st or st.attached then
		return
	end
	st.attached = true
	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function(_, b, _, first, last_old, last_new)
			local s = states[b]
			if not s then
				return true -- detach
			end
			if s.rendering then
				return false
			end
			s._by_path_dirty = true

			-- The snapshot no longer describes the buffer, so snapshot-backed
			-- lookups stop here and the buffer-walking fallback takes over.
			s.snap_clean = false

			-- Widen the dirty range (1-based, inclusive).  :w re-parses only
			-- this window instead of the whole buffer.
			local lo = first + 1
			local hi = math.max(last_old, last_new)
			s.dirty_lo = s.dirty_lo and math.min(s.dirty_lo, lo) or lo
			s.dirty_hi = s.dirty_hi and math.max(s.dirty_hi, hi) or hi
			return false
		end,
		on_detach = function(_, b)
			local s = states[b]
			if s then
				s.attached = false
			end
		end,
	})
end

----------------------------------------------------------------------
-- Path resolution (buffer walking)
----------------------------------------------------------------------

--- Parse one buffer line into name, type and indent level.
--- Returns nil when the line is empty or unparseable.
---@param line string
---@return string|nil name
---@return string|nil type   "dir" | "link" | "file"
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

--- How many lines one nvim_buf_get_lines call grabs when scanning.  The API
--- call dominates the cost of reading a line, so anything that reads more
--- than a handful of lines reads them in blocks.
local CHUNK = 128

--- Ancestor chain of the line at `lnum`, outermost first.
---
--- The parent of a line is the nearest preceding line one indent level
--- shallower, its grandparent the nearest preceding line two levels
--- shallower, and so on — so a single upward pass, picking up each
--- decreasing level in turn, reconstructs the whole chain.  Lines are read
--- in blocks: a call-per-line walk costs more than everything else in path
--- resolution put together.
---@param buf    number
---@param root   string
---@param lnum   number  1-based line whose ancestors are wanted
---@param indent number  indent level of that line
---@return table[]  { { indent, path }, ... } outermost first
local function ancestor_stack(buf, root, lnum, indent)
	local stack = {}
	local want = indent - 1
	if want < 0 then
		return stack
	end

	local segs = {} -- { name, indent }, deepest first
	local i = lnum - 1
	while want >= 0 and i >= 1 do
		local from = math.max(1, i - CHUNK + 1)
		local chunk = vim.api.nvim_buf_get_lines(buf, from - 1, i, false)
		for k = #chunk, 1, -1 do
			local name, _, ind = read_line(chunk[k])
			if name and ind == want then
				segs[#segs + 1] = { name = name, indent = ind }
				want = want - 1
				if want < 0 then
					break
				end
			end
		end
		i = from - 1
	end

	local path = root
	for j = #segs, 1, -1 do
		path = path .. "/" .. segs[j].name
		stack[#stack + 1] = { indent = segs[j].indent, path = path }
	end
	return stack
end

--- Resolve the filesystem path of `lnum` by walking up to find ancestor
--- directories and reconstructing the chain.  O(depth) — typically under
--- 20 lines per lookup.
---@param buf   number
---@param lnum  number  1-based line number
---@return string|nil path
local function resolve_path(buf, lnum)
	local st = states[buf]
	if not st or not lnum or lnum < 1 then
		return nil
	end

	local lines = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)
	local name, _, indent = read_line(lines[1])
	if not name then
		return nil
	end

	local stack = ancestor_stack(buf, st.root, lnum, indent)
	local parent = #stack > 0 and stack[#stack].path or st.root
	return parent .. "/" .. name
end

--- Walk the whole buffer once, calling `fn(lnum, path, type_, indent)` for
--- every parseable line.  The single place that turns buffer text into
--- paths in bulk — path maps, fold state and expansion all share it.
---@param buf  number
---@param root string
---@param fn   fun(lnum: number, path: string, type_: string, indent: number)
function M.walk(buf, root, fn)
	-- Snapshot fast path: iterate the visible projection, building a path only
	-- for the rows the callback actually looks at.  The fallback reads and
	-- re-parses every buffer line.
	local st = states[buf]
	if st and st.snap_clean and st.snap and st.snap.root == root then
		local snapshot = require("filebuf.snapshot")
		local snap = st.snap
		local view = snap.view
		for lnum = 1, #view do
			local row = view[lnum]
			fn(lnum, snapshot.path_of(snap, row), snapshot.type(snap, row), snap.indent[row])
		end
		return
	end

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local stack = {} -- { indent, path }

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
			end
			fn(lnum, path, type_, indent)
		end
	end
end

--- A resolver for entries at increasing line numbers — the shape every
--- viewport walk has.
---
--- The ancestor chain is reconstructed once, for the first line asked
--- about; from there it is maintained by pushing and popping as the
--- resolver moves down, so every further line costs a block-cached line
--- read and a couple of table operations instead of its own upward walk.
---
--- Lines may be skipped (closed folds), as long as the caller never moves
--- backwards: anything skipped is a descendant of the line before it, so
--- the indent-based pop still lands on the right parent.
---@param buf number
---@return fun(lnum: number): table|nil  same shape as M.resolve_entry
function M.range_resolver(buf)
	local st = states[buf]
	if not st then
		return function()
			return nil
		end
	end

	-- Block-cached line reader.
	local block_from, block = 0, nil
	local function read_at(lnum)
		if not block or lnum < block_from or lnum >= block_from + #block then
			block_from = lnum
			block = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum - 1 + CHUNK, false)
		end
		return block[lnum - block_from + 1]
	end

	local stack, seeded = {}, false

	return function(lnum)
		local name, type_, indent = read_line(read_at(lnum))
		if not name then
			return nil
		end

		if not seeded then
			seeded = true
			stack = ancestor_stack(buf, st.root, lnum, indent)
		end

		while #stack > 0 and stack[#stack].indent >= indent do
			table.remove(stack)
		end
		local parent = #stack > 0 and stack[#stack].path or st.root
		local path = parent .. "/" .. name
		if type_ == "dir" then
			stack[#stack + 1] = { indent = indent, path = path }
		end

		return {
			lnum = lnum,
			path = path,
			name = name,
			type = type_,
			indent = indent,
			is_hidden = (name:sub(1, 1) == ".") or nil,
			lazy = (type_ == "dir" and st.truncated_dirs[path]) or nil,
		}
	end
end

--- Build an entry table for the line at `lnum` by walking up the buffer
--- to reconstruct its absolute path.
---@param buf   number
---@param lnum  number  1-based
---@return table|nil  { lnum, path, name, type, indent, is_hidden }
function M.resolve_entry(buf, lnum)
	local st = states[buf]
	if not st or not lnum or lnum < 1 then
		return nil
	end

	-- Snapshot fast path: one array index plus an O(depth) parent walk, no
	-- buffer reads at all.  Only valid while the buffer is unedited.
	if st.snap_clean and st.snap then
		local entry = require("filebuf.snapshot").entry(st.snap, lnum)
		if entry then
			return entry
		end
	end

	local lines = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)
	local name, type_, indent = read_line(lines[1])
	if not name then
		return nil
	end

	local path = resolve_path(buf, lnum)
	if not path then
		return nil
	end

	local is_truncated = type_ == "dir" and st.truncated_dirs[path] or nil

	return {
		lnum = lnum,
		path = path,
		name = name,
		type = type_,
		indent = indent,
		is_hidden = (name:sub(1, 1) == ".") or nil,
		lazy = is_truncated,
	}
end

--- The entry under the cursor in the current window, or nil.
---@param buf number
---@return table|nil
function M.entry_at_cursor(buf)
	return M.resolve_entry(buf, vim.api.nvim_win_get_cursor(0)[1])
end

----------------------------------------------------------------------
-- Batch entry parsing
----------------------------------------------------------------------

--- Parse the entire buffer into entry tables (used for :w diffing).
--- Delegates to buffer.parse_buffer and adds is_hidden flags.
---@param buf number
---@return table[]
function M.entries(buf)
	local st = states[buf]
	if not st then
		return {}
	end
	local entries = require("filebuf.buffer").parse_buffer(buf, st.root)
	for _, e in ipairs(entries) do
		if e.name:sub(1, 1) == "." then
			e.is_hidden = true
		end
	end
	return entries
end

----------------------------------------------------------------------
-- Path → line lookup
----------------------------------------------------------------------

--- Build (or return a cached) path→lnum map by scanning the buffer once.
--- Invalidated automatically after edits.
---@param buf number
---@return table  path → lnum
local function build_path_map(buf)
	local st = states[buf]
	if not st then
		return {}
	end
	if st._by_path and not st._by_path_dirty then
		return st._by_path
	end

	local map = {}
	M.walk(buf, st.root, function(lnum, path)
		map[path] = lnum
	end)

	st._by_path = map
	st._by_path_dirty = false
	return map
end

--- Line number of `path`, or nil.
---@param buf  number
---@param path string
---@return number|nil
function M.lnum_of(buf, path)
	local st = states[buf]

	-- Snapshot fast path: descend the child index one path segment at a time,
	-- O(depth * siblings).  The fallback below builds a path→lnum map over the
	-- whole buffer, which on a large tree is the most expensive lookup in the
	-- plugin -- and toggle_hidden used to trigger it on every keypress.
	if st and st.snap_clean and st.snap then
		return require("filebuf.snapshot").lnum_of_path(st.snap, path)
	end

	local map = build_path_map(buf)
	return map[path]
end

--- The entry for `path`, or nil when it isn't currently displayed.
---@param buf  number
---@param path string
---@return table|nil
function M.entry_of(buf, path)
	local lnum = M.lnum_of(buf, path)
	return lnum and M.resolve_entry(buf, lnum) or nil
end

--- Set of directory paths whose fold is currently open, read back from the
--- window with foldclosed().
---
--- Costly (one vim.fn call per directory) and rarely what you want:
--- actions.open_folds already tracks this as folds are opened and closed.
--- Kept for the cases that need the window's actual state rather than the
--- plugin's record of it.
---@param buf number
---@return table  path → true
function M.open_dirs(buf)
	local st = states[buf]
	local open = {}
	if not st then
		return open
	end

	M.walk(buf, st.root, function(lnum, path, type_)
		if type_ == "dir" and vim.fn.foldclosed(lnum) == -1 then
			open[path] = true
		end
	end)

	return open
end

return M
