----------------------------------------------------------------------
-- Tree scanner.  Renders the whole non-hidden tree (not lazy) so native
-- `/` search can match any entry.  fd fast path when available, else a
-- find(1) fallback; both return the same flat DFS-ordered entry shape:
--   { name, type, path, indent, is_hidden? }  (type = dir|link|file)
----------------------------------------------------------------------
local prof = require("filebuf.profiler")
local config = require("filebuf.config")
local ignore = require("filebuf.ignore")

local M = {}

--- Sort a child list in place: dirs, then links, then files;
--- case-insensitive alphabetical within each group.
local ENTRY_PRIO = { dir = 1, link = 2, file = 3, error = 4 }
local function sort_children(children)
	if #children > 1 then
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
--- show_hidden is true, all entries are returned (hidden ones are dimmed
--- by the decoration provider).  When false, is_hidden entries are dropped
--- along with everything inside hidden directories.
---@param entries table[]  flat DFS list
---@return table[]
function M.filter_visible(entries)
	if config.show_hidden then
		return entries
	end
	local visible = {}
	-- Indent levels of hidden directories we're currently inside.  Entries
	-- are in DFS order, so we push on entering a hidden dir and pop once the
	-- indent returns to (or above) its level.
	local hidden_stack = {}
	for _, entry in ipairs(entries) do
		while #hidden_stack > 0 and entry.indent <= hidden_stack[#hidden_stack] do
			table.remove(hidden_stack)
		end
		if entry.is_hidden and entry.type == "dir" then
			hidden_stack[#hidden_stack + 1] = entry.indent
		end
		if not entry.is_hidden and #hidden_stack == 0 then
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
	local cmd = string.format(
		"find %s -mindepth 1 -maxdepth %d -printf '%%y\t%%h\t%%f\n' 2>/dev/null",
		vim.fn.shellescape(dir),
		FIND_MAXDEPTH
	)
	local lines = vim.fn.systemlist(cmd)
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
					active_patterns[#active_patterns + 1] =
						{ raw = p.raw, negate = p.negate, source_dir = parent_path }
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
	local function emit_children(parent_path, depth, inside_hidden)
		for _, entry in ipairs(by_parent[parent_path] or {}) do
			entry.indent = depth

			-- Tag hidden entries; .ignore itself is never hidden.
			if entry.name ~= ".ignore" then
				if inside_hidden then
					entry.is_hidden = true -- whole subtree inherits, skip matching
				elseif entry.name:sub(1, 1) == "." then
					entry.is_hidden = true -- dotfiles are always hidden
				elseif
					config.respect_ignore
					and #active_patterns > 0
					and ignore.matches_ignore(
						entry.path,
						entry.name,
						active_patterns,
						entry.type == "dir",
						active_negate_count
					)
				then
					entry.is_hidden = true
				end
			end

			result[#result + 1] = entry

			if entry.type == "dir" then
				local pushed = push_ignore(entry.path)
				emit_children(entry.path, depth + 1, inside_hidden or entry.is_hidden)
				pop_ignore(pushed)
			end
		end
	end

	prof.start("dfs_emit")
	emit_children(dir, 0, false)
	prof.stop() -- dfs_emit

	prof.stop()
	return result
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
	if show_hidden or not config.respect_ignore then
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
		end
	end
	prof.stop()

	prof.start("sort_children")
	for _, children in pairs(by_parent) do
		sort_children(children)
	end
	prof.stop()

	-- fd already dropped gitignored entries (when respect_ignore), so the only
	-- hidden tagging left is the dotfile prefix check (relevant with -H).
	local result = {}
	local function emit(parent, depth)
		for _, e in ipairs(by_parent[parent] or {}) do
			e.indent = depth
			if show_hidden and e.name:sub(1, 1) == "." then
				e.is_hidden = true
			end
			result[#result + 1] = e
			if e.type == "dir" then
				emit(e.path, depth + 1) -- symlinks are never followed
			end
		end
	end
	emit(dir, 0)

	prof.stop()
	return result
end

--- Scan the tree, using fd when available and find otherwise.
---@param dir string
---@return table[]
function M.scan_tree(dir)
	if fd_cmd() then
		return scan_fd(dir)
	end
	return read_dir_recursive(dir)
end

return M
