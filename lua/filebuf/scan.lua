----------------------------------------------------------------------
-- Tree scanner.  Regular entries are fully materialized so native `/`
-- search can match any entry; hidden/ignored directories are lazy
-- placeholders whose children are loaded on demand.
-- fd fast path when available, else a find(1) fallback; both return the
-- same flat DFS-ordered entry shape:
--   { name, type, path, indent, is_hidden?, is_ignored?, lazy? }  (type = dir|link|file)
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
-- find(1) fallback scanner
----------------------------------------------------------------------

local FIND_MAXDEPTH = 21 -- legacy default: max_depth 20 + 1

--- Recursively read a directory tree using a single find(1) subprocess,
--- returning the flat entry list.  Reads .ignore/.gitignore on the way down
--- to tag hidden entries.  Symlinks are atomic entries (type "link"),
--- never followed.
---@param dir string
---@return table[]
local function read_dir_recursive(dir)
	prof.start("read_dir_recursive")

	-- %y = type char (d/f/l), %h = parent dir, %f = basename.  Letting find
	-- split dirname/basename in C avoids per-entry Lua path decomposition.
	prof.start("read_dir")
	-- Build argv with -path ... -prune and -path expressions derived
	-- -name is an O(1) basename comparison; -prune on the directory itself
	-- prevents find from ever descending into it, so children are never
	-- stat'd or printed.  Table-arg systemlist avoids shell escaping.
	local argv = { "find", dir }
	vim.list_extend(argv, { "-mindepth", "1", "-maxdepth", tostring(FIND_MAXDEPTH) })
	-- Expressions from .gitignore/.ignore ordered cheapest→most-expensive.
	-- find's -path `*` wildcard crosses "/" (fnmatch without FNM_PATHNAME).
	if config.respect_ignore then
		local groups = ignore.extract_find_expressions(dir)
		for _, group in ipairs(groups) do
			for _, expr in ipairs(group) do
				vim.list_extend(argv, expr.tokens)
				argv[#argv + 1] = "-o"
			end
		end
	end
	argv[#argv + 1] = "-printf"
	argv[#argv + 1] = "%y\t%h\t%f\n"
	local lines = vim.fn.systemlist(argv)
	prof.stop() -- read_dir

	prof.start("parse_find_output")
	local by_parent = {} -- parent_path → { entry, ... }
	local TYPE_MAP = { d = "dir", l = "link", f = "file" }
	for _, line in ipairs(lines) do
		local type_char, parent, name = line:match("^(.)\t(.+)\t(.+)$")
		local type_label = type_char and TYPE_MAP[type_char]
		if type_label and parent and name then
			local lst = by_parent[parent]
			if not lst then
				lst = {}
				by_parent[parent] = lst
			end
			lst[#lst + 1] = { name = name, type = type_label, path = parent .. "/" .. name }
		end
	end
	prof.stop() -- parse_find_output

	prof.start("sort_children")
	for _, children in pairs(by_parent) do
		sort_children(children)
	end
	prof.stop() -- sort_children

	-- Mutable stack of active ignore patterns, pushed on entering a directory
	-- and popped on leaving.  active_negate_count lets matches_ignore early-exit
	-- when no negation patterns are in scope.
	local active_patterns = {}
	local active_negate_count = 0

	--- Read a directory's .ignore/.gitignore (found in by_parent, so no stat
	--- syscall) and push its patterns; returns how many were pushed.
	local function push_ignore(parent_path)
		if not config.respect_ignore then
			return 0
		end
		local pushed = 0
		for _, child in ipairs(by_parent[parent_path] or {}) do
			if child.name == ".ignore" or child.name == ".gitignore" then
				for _, p in ipairs(ignore.parse_ignore_file(child.path)) do
					active_patterns[#active_patterns + 1] = { raw = p.raw, negate = p.negate, source_dir = parent_path }
					if p.negate then
						active_negate_count = active_negate_count + 1
					end
					pushed = pushed + 1
				end
			end
		end
		return pushed
	end

	local function pop_ignore(n)
		for _ = 1, n do
			if active_patterns[#active_patterns].negate then
				active_negate_count = active_negate_count - 1
			end
			active_patterns[#active_patterns] = nil
		end
	end

	prof.start("setup_ignore")
	push_ignore(dir) -- root .ignore before descending
	prof.stop() -- setup_ignore

	-- DFS: build the flat result, tagging hidden entries via the pattern stack.
	local result = {}
	local function emit_children(parent_path, depth, inside_ignored)
		for _, entry in ipairs(by_parent[parent_path] or {}) do
			entry.indent = depth

			-- Tag hidden / ignored entries; .ignore itself is never tagged.
			if entry.name ~= ".ignore" then
				if inside_ignored then
					entry.is_ignored = true -- whole subtree inherits, skip matching
				elseif entry.name:sub(1, 1) == "." then
					entry.is_hidden = true -- dotfiles are always hidden
				end
				if
					not entry.is_hidden
					and not entry.is_ignored
					and config.respect_ignore
					and #active_patterns > 0
					and ignore.matches_ignore(
						entry.path,
						entry.name,
						active_patterns,
						entry.type == "dir",
						active_negate_count
					)
				then
					entry.is_ignored = true
				end
			end

			result[#result + 1] = entry

			if entry.type == "dir" then
				if entry.is_hidden or entry.is_ignored then
					-- Hidden/ignored directory: mark lazy, don't recurse.
					-- Children stay in by_parent for on-demand expansion.
					entry.lazy = true
				else
					local pushed = push_ignore(entry.path)
					emit_children(entry.path, depth + 1, inside_ignored or entry.is_ignored)
					pop_ignore(pushed)
				end
			end
		end
	end

	prof.start("dfs_emit")
	emit_children(dir, 0, false)
	prof.stop() -- dfs_emit

	prof.stop()
	return result, by_parent
end

----------------------------------------------------------------------
-- fd fast-path scanner
----------------------------------------------------------------------

--- Cached fd executable name ("fd" or "fdfind"); false when absent.
local _fd_cmd
local function fd_cmd()
	if _fd_cmd == nil then
		if vim.fn.executable("fd") == 1 then
			_fd_cmd = "fd"
		elseif vim.fn.executable("fdfind") == 1 then
			_fd_cmd = "fdfind"
		else
			_fd_cmd = false
		end
	end
	return _fd_cmd or nil
end

--- Scan `dir` with fd.  fd natively skips .git/ contents and respects
--- .gitignore/.ignore, so giant ignored subtrees are never traversed.
--- Symlinks appear as atomic entries (type "link"), never followed.
---@param dir string
---@return table[]
local function scan_fd(dir)
	prof.start("scan_fd")
	local show_hidden = config.show_hidden

	-- -H includes dot entries; -I disables .gitignore/.ignore filtering (so
	-- .venv/, node_modules/ etc. still appear, dimmed, with show_hidden, or
	-- when the user disabled respect_ignore).
	local flags = { "--color", "never" }
	if show_hidden then
		flags[#flags + 1] = "-H"
	end
	if not config.respect_ignore then
		flags[#flags + 1] = "-I"
	end
	local function run(extra)
		local argv = { fd_cmd() }
		vim.list_extend(argv, flags)
		vim.list_extend(argv, extra)
		argv[#argv + 1] = "."
		argv[#argv + 1] = dir
		return vim.fn.systemlist(argv)
	end

	-- Main scan (fd appends "/" to directories) + a symlink-only pass so we
	-- can tag type "link" without a per-entry stat.
	prof.start("fd_scan")
	local fd_out = run({})
	prof.stop()

	prof.start("fd_scan_links")
	local symlink_set = {}
	for _, p in ipairs(run({ "-t", "l" })) do
		if p ~= "" then
			symlink_set[p:sub(-1) == "/" and p:sub(1, -2) or p] = true
		end
	end
	prof.stop()

	prof.start("parse_fd_output")
	local by_parent = {}
	local regular_children = {} -- parent_path → { child_name = true }
	for _, raw in ipairs(fd_out) do
		if raw ~= "" then
			local is_dir = raw:sub(-1) == "/"
			local full = is_dir and raw:sub(1, -2) or raw
			local etype = symlink_set[full] and "link" or (is_dir and "dir" or "file")

			local parent, name = full:match("^(.*)/(.+)$")
			if not parent then
				parent, name = dir, full
			end

			local lst = by_parent[parent]
			if not lst then
				lst = {}
				by_parent[parent] = lst
			end
			lst[#lst + 1] = { name = name, type = etype, path = full }

			-- Track what fd returned so we can cross-reference with fs_scandir.
			if not regular_children[parent] then
				regular_children[parent] = {}
			end
			regular_children[parent][name] = true
		end
	end
	prof.stop()

	prof.start("sort_children")
	for _, children in pairs(by_parent) do
		sort_children(children)
	end
	prof.stop()

	-- Helper: find hidden/ignored subdirectories via fs_scandir cross-reference.
	-- Anything fs_scandir finds that fd did NOT return is either hidden (dot-prefix)
	-- or gitignored; directories become lazy placeholders.
	local function find_lazy_subdirs(parent_path, regular_set)
		local handle = vim.loop.fs_scandir(parent_path)
		if not handle then
			return {}
		end
		local lazy = {}
		while true do
			local name, ftype = vim.loop.fs_scandir_next(handle)
			if not name then
				break
			end
			if regular_set[name] then
				goto continue
			end
			if ftype == "directory" then
				-- All directories found here were excluded by fd (either
				-- dot-prefixed or gitignored); tag them so filter_visible
				-- hides them when show_hidden is off.
				local is_dotfile = name:sub(1, 1) == "."
				lazy[#lazy + 1] = {
					name = name,
					type = "dir",
					path = parent_path .. "/" .. name,
					is_hidden = is_dotfile or nil,
					is_ignored = (not is_dotfile and config.respect_ignore) or nil,
					lazy = true,
				}
			else
				-- Hidden/ignored file/link that fd excluded.  Always
				-- collect them so toggling show_hidden is a pure re-filter
				-- of the cached list.
				local etype = ftype == "link" and "link" or "file"
				local is_dotfile = name:sub(1, 1) == "."
				lazy[#lazy + 1] = {
					name = name,
					type = etype,
					path = parent_path .. "/" .. name,
					is_hidden = is_dotfile or nil,
					is_ignored = (not is_dotfile and config.respect_ignore) or nil,
				}
			end
			::continue::
		end
		sort_children(lazy)
		return lazy
	end

	-- DFS emit — interleaves lazy placeholders with regular children.
	-- Dot-prefixed directories from the regular output are also marked lazy
	-- so hidden dirs are never eagerly expanded.
	local result = {}
	local function emit(parent, depth)
		local regular = by_parent[parent] or {}
		local lazy_dirs = find_lazy_subdirs(parent, regular_children[parent] or {})

		-- Merge and sort: lazy placeholders + regular entries.
		local all_children = {}
		for _, e in ipairs(lazy_dirs) do
			all_children[#all_children + 1] = e
		end
		for _, e in ipairs(regular) do
			-- Dot-prefixed directories from the fd output are also lazy
			-- (their children were scanned by fd but we skip recursing).
			if e.type == "dir" and e.name:sub(1, 1) == "." then
				e.lazy = true
				e.is_hidden = true
			elseif show_hidden and e.name:sub(1, 1) == "." then
				e.is_hidden = true
			end
			all_children[#all_children + 1] = e
		end
		sort_children(all_children)

		for _, e in ipairs(all_children) do
			e.indent = depth
			result[#result + 1] = e
			if e.type == "dir" and not e.lazy then
				emit(e.path, depth + 1) -- symlinks are never followed
			end
		end
	end
	emit(dir, 0)

	prof.stop()
	return result
end

--- Scan the immediate children of a single directory.  Used when expanding a
--- lazy directory on demand.
---
--- If `by_parent_cache` is provided (from the find fallback), children are
--- read directly from the cache with zero filesystem access.  Otherwise the
--- directory is read via vim.loop.fs_scandir, with dot-prefixed subdirs
--- marked lazy and gitignored entries checked via the ignore module.
---@param dir              string  directory path
---@param by_parent_cache? table   parent→children map from find fallback
---@return table[]  child entries (no indent set; caller supplies it)
function M.scan_dir_children(dir, by_parent_cache)
	-- Cached path (find fallback): emit children directly from the cache.
	if by_parent_cache and by_parent_cache[dir] then
		local children = {}
		for _, e in ipairs(by_parent_cache[dir]) do
			local entry = {
				name = e.name,
				type = e.type,
				path = dir .. "/" .. e.name,
			}
			-- All subdirectories are lazy when expanding on demand: we only
			-- loaded one level, so their children haven't been scanned yet.
			if e.type == "dir" then
				entry.lazy = true
			end
			if e.is_hidden then
				entry.is_hidden = true
			end
			if e.is_ignored then
				entry.is_ignored = true
			end
			children[#children + 1] = entry
		end
		sort_children(children)
		return children
	end

	-- Uncached path (fd fast path): use fs_scandir + ignore matching.
	local handle = vim.loop.fs_scandir(dir)
	if not handle then
		return {}
	end

	-- Load ignore patterns for this directory.
	local active_patterns, active_negate_count = {}, 0
	if config.respect_ignore then
		local function load_ignore(name)
			local ipath = dir .. "/" .. name
			local fstat = vim.loop.fs_stat(ipath)
			if fstat and fstat.type == "file" then
				for _, p in ipairs(ignore.parse_ignore_file(ipath)) do
					active_patterns[#active_patterns + 1] = {
						raw = p.raw,
						negate = p.negate,
						source_dir = dir,
					}
					if p.negate then
						active_negate_count = active_negate_count + 1
					end
				end
			end
		end
		load_ignore(".ignore")
		load_ignore(".gitignore")
	end

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
			-- All subdirectories are lazy when expanding on demand: we only
			-- load one level, so their children haven't been scanned yet.
			entry.lazy = true
			-- Hidden (dot-prefix) or ignored (gitignore match).
			local is_dotfile = name:sub(1, 1) == "."
			local is_ignored = config.respect_ignore
				and #active_patterns > 0
				and ignore.matches_ignore(child_path, name, active_patterns, true, active_negate_count)
			if is_dotfile then
				entry.is_hidden = true
			end
			if is_ignored then
				entry.is_ignored = true
			end
		elseif ftype == "link" then
			entry.type = "link"
		else
			entry.type = "file"
		end

		-- Tag dot-prefixed files/links as hidden.
		if name:sub(1, 1) == "." then
			entry.is_hidden = true
		end
		-- Check gitignore for files/links too (directories handled above).
		if
			not entry.is_ignored
			and config.respect_ignore
			and #active_patterns > 0
			and ignore.matches_ignore(child_path, name, active_patterns, false, active_negate_count)
		then
			entry.is_ignored = true
		end

		children[#children + 1] = entry
	end
	sort_children(children)
	return children
end

--- Scan the tree, using fd when available and find otherwise.
--- Returns the flat DFS-ordered entry list and, for the find fallback,
--- the by-parent cache so lazy expansions can reuse in-memory data.
---@param dir string
---@return table[] entries
---@return table?   by_parent  present only for the find fallback
function M.scan_tree(dir)
	if fd_cmd() then
		return scan_fd(dir), nil
	end
	return read_dir_recursive(dir)
end

return M
