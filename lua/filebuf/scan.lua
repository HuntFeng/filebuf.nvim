----------------------------------------------------------------------
-- Tree scanner.  Every directory is a lazy placeholder: opening a filebuf
-- loads only the root's immediate children (one fs_scandir), and children
-- appear when the user expands a directory (see actions.expand_dir) or when
-- a search reveals a path (see actions.reveal_path).
--
-- Nothing is filtered out at scan time — hidden and gitignored entries are
-- materialized too, tagged with is_hidden / is_ignored.  That makes the
-- show_hidden toggle a pure, lossless re-filter (see filter_visible).
--
-- Flat DFS-ordered entry shape:
--   { name, type, path, indent, is_hidden?, is_ignored?, lazy? }  (type = dir|link|file)
--
-- The pre-lazy whole-tree fd/find scanners are preserved for reference in
-- scan_eager.lua.bak (not loaded).
----------------------------------------------------------------------
local prof = require("filebuf.profiler")
local config = require("filebuf.config")
local ignore = require("filebuf.ignore")

local M = {}

--- Sort a child list in place according to the configured sort method.
--- "type"     — dirs, then links, then files; alpha within each group.
--- "name"     — case-insensitive alphabetical.
--- "modified" — most recently modified first; ties broken alphabetically.
--- "created"  — most recently created first (birthtime or mtime fallback).
local ENTRY_PRIO = { dir = 1, link = 2, file = 3, error = 4 }
local function sort_children(children, sort_method)
	if #children <= 1 then
		return
	end
	sort_method = sort_method or config.sort_method

	if sort_method == "name" then
		table.sort(children, function(a, b)
			return a.name:lower() < b.name:lower()
		end)
	elseif sort_method == "modified" then
		-- Stat entries to get mtime; cache on entry so repeated sorts are free.
		for _, e in ipairs(children) do
			if not e._stat then
				e._stat = vim.loop.fs_stat(e.path)
			end
		end
		table.sort(children, function(a, b)
			local ta = (a._stat and a._stat.mtime and a._stat.mtime.sec) or 0
			local tb = (b._stat and b._stat.mtime and b._stat.mtime.sec) or 0
			if ta ~= tb then
				return ta > tb -- newest first
			end
			return a.name:lower() < b.name:lower()
		end)
	elseif sort_method == "created" then
		for _, e in ipairs(children) do
			if not e._stat then
				e._stat = vim.loop.fs_stat(e.path)
			end
		end
		table.sort(children, function(a, b)
			local function btime_sec(entry)
				local st = entry._stat
				if not st then
					return 0
				end
				local bt = st.birthtime or st.mtime
				return bt and bt.sec or 0
			end
			local ba = btime_sec(a)
			local bb = btime_sec(b)
			if ba ~= bb then
				return ba > bb -- newest first
			end
			return a.name:lower() < b.name:lower()
		end)
	else -- "type" (default)
		table.sort(children, function(a, b)
			local pa = ENTRY_PRIO[a.type] or 5
			local pb = ENTRY_PRIO[b.type] or 5
			if pa ~= pb then
				return pa < pb
			end
			return a.name:lower() < b.name:lower()
		end)
	end
end

----------------------------------------------------------------------
-- Visibility filter
----------------------------------------------------------------------

--- Return only the entries that should appear in the buffer.  When
--- show_hidden is true, all entries are returned (hidden/ignored ones are dimmed
--- by the decoration provider).  When false, is_hidden / is_ignored entries are
--- dropped along with everything inside hidden/ignored directories.
---@param entries table[]  flat DFS list
---@return table[]
function M.filter_visible(entries)
	if config.show_hidden then
		return entries
	end
	local visible = {}
	-- Indent levels of hidden/ignored directories we're currently inside.  Entries
	-- are in DFS order, so we push on entering a hidden/ignored dir and pop once
	-- the indent returns to (or above) its level.
	local hidden_stack = {}
	for _, entry in ipairs(entries) do
		while #hidden_stack > 0 and entry.indent <= hidden_stack[#hidden_stack] do
			table.remove(hidden_stack)
		end
		local dimmed = entry.is_hidden or entry.is_ignored
		if dimmed and entry.type == "dir" then
			hidden_stack[#hidden_stack + 1] = entry.indent
		end
		if not dimmed and #hidden_stack == 0 then
			visible[#visible + 1] = entry
		end
	end
	return visible
end

----------------------------------------------------------------------
-- Ignore patterns in scope for a directory
----------------------------------------------------------------------

--- dir → { patterns = table[], negate_count = number }, accumulated from the
--- filebuf root down to `dir`.  Cleared by M.clear_ignore_cache() so edits to
--- .gitignore / .ignore on disk take effect on the next scan.
local _ignore_cache = {}

--- Drop the accumulated-ignore-pattern cache.  Call before a fresh scan.
function M.clear_ignore_cache()
	_ignore_cache = {}
end

--- Ignore patterns in scope for `dir`, accumulated from `root` downward.
---
--- The pre-lazy find(1) scanner pushed and popped patterns as it descended, so
--- a deep entry was matched against every ancestor's rules.  Lazy scanning
--- reaches a directory without having walked its ancestors, so the chain is
--- rebuilt here instead — memoised per directory, and the parent's list is
--- reused, so descending one level costs one .ignore/.gitignore read.
---@param root string  filebuf root (recursion stops here)
---@param dir  string  directory to collect patterns for
---@return table[] patterns
---@return number  negate_count
local function ignore_patterns_for(root, dir)
	local cached = _ignore_cache[dir]
	if cached then
		return cached.patterns, cached.negate_count
	end

	local patterns, negate_count = {}, 0
	-- Inherit the parent's accumulated patterns unless we're at (or outside) the
	-- root.  Copied rather than shared so each level can append its own without
	-- mutating the parent's cached list.
	local parent = dir ~= root and vim.startswith(dir, root .. "/") and dir:match("^(.*)/[^/]+$") or nil
	if parent then
		local parent_patterns, parent_negate_count = ignore_patterns_for(root, parent)
		for i = 1, #parent_patterns do
			patterns[i] = parent_patterns[i]
		end
		negate_count = parent_negate_count
	end

	for _, fname in ipairs({ ".ignore", ".gitignore" }) do
		local ipath = dir .. "/" .. fname
		local fstat = vim.loop.fs_stat(ipath)
		if fstat and fstat.type == "file" then
			for _, p in ipairs(ignore.parse_ignore_file(ipath)) do
				patterns[#patterns + 1] = { raw = p.raw, negate = p.negate, source_dir = dir }
				if p.negate then
					negate_count = negate_count + 1
				end
			end
		end
	end

	_ignore_cache[dir] = { patterns = patterns, negate_count = negate_count }
	return patterns, negate_count
end

----------------------------------------------------------------------
-- Single-level scan
----------------------------------------------------------------------

--- Scan the immediate children of a single directory.  Every subdirectory
--- comes back marked `lazy` — its own children are loaded only when it is
--- expanded.  Hidden (dot-prefixed) and gitignored entries are included and
--- tagged rather than dropped, so show_hidden stays a pure re-filter.
---
--- Symlinks are atomic entries (type "link") and never followed.
---@param dir   string  directory to read
---@param root? string  filebuf root, for accumulating ancestor ignore rules
---                     (defaults to `dir`, i.e. only this dir's ignore files)
---@return table[]  child entries (no indent set; caller supplies it)
function M.scan_dir_children(dir, root)
	prof.start("scan_dir_children")
	local handle = vim.loop.fs_scandir(dir)
	if not handle then
		prof.stop()
		return {}
	end

	local active_patterns, active_negate_count = {}, 0
	if config.respect_ignore then
		active_patterns, active_negate_count = ignore_patterns_for(root or dir, dir)
	end
	local has_patterns = #active_patterns > 0

	local children = {}
	while true do
		local name, ftype = vim.loop.fs_scandir_next(handle)
		if not name then
			break
		end
		local child_path = dir .. "/" .. name
		local entry = { name = name, path = child_path }

		if ftype == "directory" then
			entry.type = "dir"
			-- Lazy by default: only one level is ever loaded at a time.
			entry.lazy = true
		elseif ftype == "link" then
			entry.type = "link"
		else
			entry.type = "file"
		end

		-- Dot-prefixed entries are always hidden.
		if name:sub(1, 1) == "." then
			entry.is_hidden = true
		end
		-- .ignore itself is never tagged as ignored (matching the old scanner).
		if
			name ~= ".ignore"
			and config.respect_ignore
			and has_patterns
			and ignore.matches_ignore(child_path, name, active_patterns, entry.type == "dir", active_negate_count)
		then
			entry.is_ignored = true
		end

		children[#children + 1] = entry
	end

	sort_children(children)
	prof.stop()
	return children
end

--- Count the entries a recursive expand of `dir` would put on screen, so the
--- caller can warn before loading a huge subtree.
---
--- Mirrors what expand_dir_recursive actually does: it only descends into
--- directories that are in the display list, so hidden/ignored subtrees are
--- skipped entirely while show_hidden is off.  Counting stops as soon as `cap`
--- is reached, which bounds the walk on an arbitrarily large tree.
---@param dir   string  directory to count below (not itself counted)
---@param root? string  filebuf root, for accumulating ancestor ignore rules
---@param cap?  number  stop counting here (default: no limit)
---@return number  count   entries found, at most `cap`
---@return boolean capped  the cap was reached, so the real total is larger
function M.count_subtree(dir, root, cap)
	prof.start("count_subtree")
	root = root or dir
	cap = cap or math.huge

	local count = 0
	local capped = false
	local pending = { dir }
	while #pending > 0 and not capped do
		local current = table.remove(pending)
		for _, child in ipairs(M.scan_dir_children(current, root)) do
			local dimmed = child.is_hidden or child.is_ignored
			if config.show_hidden or not dimmed then
				count = count + 1
				if count >= cap then
					capped = true
					break
				end
				if child.type == "dir" then
					pending[#pending + 1] = child.path
				end
			end
		end
	end

	prof.stop()
	return count, capped
end

--- Scan the root of the tree: its immediate children at indent 0.  Everything
--- below is lazy and loaded on demand.
---@param dir string
---@return table[] entries
function M.scan_tree(dir)
	prof.start("scan_tree")
	local entries = M.scan_dir_children(dir, dir)
	for _, e in ipairs(entries) do
		e.indent = 0
	end
	prof.stop()
	return entries
end

return M
