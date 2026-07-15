local M = {}

--- Plugin configuration (set via setup()).
---@class filebuf.Config
---@field permanent_delete boolean  when false, deleted entries are moved to a trash directory
---@field auto_focus_current_file boolean  when true, focus the tree on the file
---                                        that was open before :Filebuf
---                                        (default: true)
M.config = {
	permanent_delete = true,
	auto_focus_current_file = true,
	--- when true, show git status indicators (A, M, D, …) next to entries
	--- that have uncommitted changes (default: true)
	git_status = true,
	--- when false, entries whose name starts with "." are hidden from the
	--- buffer (default: false)
	show_hidden = false,
	--- when true, .ignore files in directories are read and their patterns
	--- are used to filter entries. The .ignore file itself is never hidden.
	--- (default: true)
	respect_ignore = true,
}

--- Persisted fold-closed state, keyed by root directory.
--- Each value is a set of filesystem paths whose folds were closed.
--- Survives buffer close/reopen so the user's fold preferences stick.
M._fold_closed = {}

----------------------------------------------------------------------
-- Profiler — lightweight cumulative timer (enable with M.profile(true))
----------------------------------------------------------------------
local prof = { enabled = false, _timers = {}, _stack = {} }
local function _p_start(name)
	if not prof.enabled then
		return
	end
	prof._stack[#prof._stack + 1] = { name = name, t = vim.loop.hrtime() }
end
local function _p_end()
	if not prof.enabled then
		return
	end
	local s = prof._stack[#prof._stack]
	if not s then
		return
	end
	prof._stack[#prof._stack] = nil
	local elapsed = (vim.loop.hrtime() - s.t) / 1e6 -- ms
	local t = prof._timers[s.name]
	if not t then
		t = { total = 0, count = 0, min = math.huge, max = 0 }
		prof._timers[s.name] = t
	end
	t.total = t.total + elapsed
	t.count = t.count + 1
	if elapsed < t.min then
		t.min = elapsed
	end
	if elapsed > t.max then
		t.max = elapsed
	end
end
function M.profile(enable)
	prof.enabled = enable
	prof._timers = {}
	prof._stack = {}
	vim.notify("filebuf: profiling " .. (enable and "ON" or "OFF"), vim.log.levels.INFO)
end
function M.profile_report()
	local lines = { "=== filebuf profile ===" }
	-- Sort by total time descending
	local sorted = {}
	for name, t in pairs(prof._timers) do
		sorted[#sorted + 1] =
			{ name = name, total = t.total, count = t.count, min = t.min, max = t.max, avg = t.total / t.count }
	end
	table.sort(sorted, function(a, b)
		return a.total > b.total
	end)
	local grand_total = 0
	for _, s in ipairs(sorted) do
		grand_total = grand_total + s.total
	end
	for _, s in ipairs(sorted) do
		local pct = grand_total > 0 and string.format("(%.0f%%)", s.total / grand_total * 100) or ""
		lines[#lines + 1] = string.format(
			"  %-35s %8.2f ms  x%-4d  %s  (min %.2f, max %.2f, avg %.2f)",
			s.name,
			s.total,
			s.count,
			pct,
			s.min,
			s.max,
			s.avg
		)
	end
	lines[#lines + 1] = string.format("  %-35s %8.2f ms", "TOTAL", grand_total)
	-- Print to :messages so the user can review with :messages
	for _, line in ipairs(lines) do
		vim.api.nvim_echo({ { line .. "\n", "Normal" } }, true, {})
	end
	vim.notify("filebuf: profile report printed to :messages", vim.log.levels.INFO)
	return lines
end

----------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------

--- Parse a .ignore file and return a list of patterns, each with
--- a `negate` flag.  Supports # comments, blank lines, and trailing /
--- for dir-only patterns.  Negation patterns (starting with `!`)
--- re-include files that would otherwise be ignored by an earlier
--- pattern; in gitignore semantics the last matching pattern wins.
---@param path string  full filesystem path to the .ignore file
---@return table[]  list of { raw = string, negate = boolean }
local function parse_ignore_file(path)
	local lines = vim.fn.readfile(path)
	if type(lines) ~= "table" then
		return {}
	end
	local patterns = {}
	for _, line in ipairs(lines) do
		-- Strip leading/trailing whitespace
		line = line:match("^%s*(.-)%s*$")
		-- Skip blank lines and comments
		if line ~= "" and line:sub(1, 1) ~= "#" then
			local negate = false
			-- A leading "!" means negate (re-include) the pattern.
			-- "\!" at the start is an escaped literal "!".
			if line:sub(1, 1) == "!" then
				negate = true
				line = line:sub(2)
			elseif line:sub(1, 2) == "\\!" then
				line = line:sub(2) -- strip the backslash, keep literal "!"
			end
			table.insert(patterns, { raw = line, negate = negate })
		end
	end
	return patterns
end

--- Check if an entry matches any ignore pattern.
--- Supports: * wildcard (any sequence of chars), trailing / (dir-only),
--- path-based patterns (containing "/"), and negation patterns (starting
--- with !).  The last matching pattern wins — a negation that appears
--- later in the ignore file overrides an earlier positive match.
---
--- Compiled Lua patterns are cached on the pattern object (_lua_pattern,
--- _dir_only, _has_slash) so the glob→Lua conversion happens only once
--- per ignore-file pattern, not once per filesystem entry.
---@param full_path string    full filesystem path of the entry
---@param name      string    entry basename
---@param patterns  table[]   { raw = string, negate? = boolean, source_dir = string }
---@param is_dir    boolean   whether the entry is a directory
---@return boolean
local function matches_ignore(full_path, name, patterns, is_dir, negate_count)
	_p_start("matches_ignore")
	if not patterns or #patterns == 0 then
		_p_end()
		return false
	end
	-- When no negation patterns are active, the first match is definitive
	-- and we can skip the rest of the pattern list entirely.
	local can_early_exit = (negate_count or 0) == 0
	local matched = false
	for _, pat in ipairs(patterns) do
		-- Compile glob → Lua pattern once, then cache on the object
		if not pat._lua_pattern then
			local p = pat.raw
			local dir_only = p:sub(-1) == "/"
			if dir_only then
				p = p:sub(1, -2)
			end
			-- Escape all Lua magic characters except *, then replace * with .*
			local escaped = p:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1")
			escaped = escaped:gsub("%*", ".*")
			pat._lua_pattern = "^" .. escaped .. "$"
			pat._dir_only = dir_only
			pat._has_slash = pat.raw:find("/") ~= nil
		end

		if pat._dir_only and not is_dir then
		-- skip — trailing-slash patterns only match directories
		else
			local target
			if pat._has_slash then
				target = full_path:sub(#pat.source_dir + 2) -- strip source_dir + "/"
			else
				target = name
			end
			if target and target:match(pat._lua_pattern) then
				if can_early_exit then
					_p_end()
					return true
				end
				matched = not pat.negate -- negation patterns un-ignore
			end
		end
	end
	_p_end()
	return matched
end

--- Width of one indent level in spaces (when expandtab is set).
---@return number
local function indent_width()
	local sw = vim.go.shiftwidth
	return (sw > 0 and sw) or vim.go.tabstop
end

--- Build the indent prefix for a given depth level.
---@param level number
---@return string
local function indent_str(level)
	if level <= 0 then
		return ""
	end
	if not vim.go.expandtab then
		return string.rep("\t", level)
	end
	return string.rep(" ", level * indent_width())
end

--- Compute the indent depth level from a buffer line's leading whitespace.
---@param line string
---@return number
local function indent_level(line)
	local ws = line:match("^(%s*)") or ""
	if not vim.go.expandtab then
		local _, count = ws:gsub("\t", "")
		return count
	end
	return math.floor(#ws / indent_width())
end

--- Filter entries based on the current show_hidden config.
--- Returns only the entries that should be visible in the buffer.
--- When show_hidden is true, all entries are returned (hidden ones
--- will be dimmed via the decoration provider).  When false, entries
--- tagged is_hidden are excluded, along with all descendants of
--- hidden directories (so .git/contents don't leak into the tree).
---@param entries table[]  flat list from read_dir_recursive
---@return table[]
local function filter_visible(entries)
	if M.config.show_hidden then
		return entries
	end
	local visible = {}
	-- Stack of indent levels of hidden directories we're currently inside.
	-- Since entries are in depth-first tree order, we push when we enter a
	-- hidden dir and pop when indent returns to (or above) the dir's level.
	local hidden_stack = {}
	for _, entry in ipairs(entries) do
		-- Pop hidden directories we've exited (indent is back at or above
		-- the hidden dir's level, i.e. we're in a different subtree).
		while #hidden_stack > 0 and entry.indent <= hidden_stack[#hidden_stack] do
			table.remove(hidden_stack)
		end

		local inside_hidden = #hidden_stack > 0

		if entry.is_hidden and entry.type == "dir" then
			table.insert(hidden_stack, entry.indent)
		end

		if not entry.is_hidden and not inside_hidden then
			table.insert(visible, entry)
		end
	end
	return visible
end

--- Recursively read a directory tree using find(1) for fast I/O,
--- returning a flat list with indent levels and hidden tagging.
--- A single find subprocess replaces thousands of per-directory
--- readdir+stat calls, giving a ~100-500× speedup on large trees.
---
--- Uses cycle detection via real paths to handle symlinks safely.
---@param dir string
---@param max_depth number|nil
---@param current_depth number
--- Symlinks are never followed — they appear as atomic entries (type "link").
---@param ancestor_patterns? table[]  { raw, source_dir } patterns from parents
---@return table[]  list of { name, type, path, indent, is_hidden? }
local function read_dir_recursive(dir, max_depth, current_depth, ancestor_patterns)
	_p_start("read_dir_recursive")
	current_depth = current_depth or 0
	max_depth = max_depth or 20


	-- Compute remaining depth budget for find (+1 because
	-- current_depth starts at 0 for the root but -mindepth 1
	-- makes the first level of output correspond to indent 0).
	local find_depth = max_depth - current_depth + 1
	if find_depth <= 0 then
		_p_end()
		return {}
	end

	-- Use find(1) to get all entries under dir in one subprocess call.
	-- %y = type char (d/f/l), %h = parent dir, %f = basename.
	-- Let find compute dirname/basename in C to avoid Lua regex per entry.
	-- Redirect stderr so permission errors don't leak into the output.
	_p_start("read_dir")
	local cmd = string.format(
		"find %s -mindepth 1 -maxdepth %d -printf '%%y\t%%h\t%%f\n' 2>/dev/null",
		vim.fn.shellescape(dir),
		find_depth
	)
	local lines = vim.fn.systemlist(cmd)
	_p_end() -- read_dir

	_p_start("parse_find_output")
	-- Parse the flat listing into a parent→children map.
	-- find already split dirname/basename for us, so no Lua-level
	-- path decomposition is needed per entry.
	local by_parent = {} -- parent_path → { entry, ... }
	local TYPE_MAP = { d = "dir", l = "link", f = "file" }
	for _, line in ipairs(lines) do
		local type_char, parent, name = line:match("^(.)\t(.+)\t(.+)$")
		if type_char and parent and name then
			local type_label = TYPE_MAP[type_char]
			if type_label then
				local path = parent .. "/" .. name
				local entry = {
					name = name,
					type = type_label,
					path = path,
				}

				local lst = by_parent[parent]
				if not lst then
					lst = {}
					by_parent[parent] = lst
				end
				lst[#lst + 1] = entry
			end
		end
	end
	_p_end() -- parse_find_output

	_p_start("sort_children")
	-- Sort children within each parent: dirs first, then links, then files;
	-- case-insensitive alphabetical within each group.
	-- Skip sort for single-element directories (common case in sparse trees).
	for _, children in pairs(by_parent) do
		if #children > 1 then
			table.sort(children, function(a, b)
				local prio = { dir = 1, link = 2, file = 3, error = 4 }
				local pa = prio[a.type] or 5
				local pb = prio[b.type] or 5
				if pa ~= pb then
					return pa < pb
				end
				return a.name:lower() < b.name:lower()
			end)
		end
	end
	_p_end() -- sort_children

	-- Mutable stack of active ignore patterns.  Patterns are pushed when
	-- entering a directory (reading its .ignore/.gitignore) and popped
	-- when leaving — no per-entry table copying needed.
	-- active_negate_count tracks how many patterns have negate=true,
	-- letting matches_ignore early-exit when no negation patterns exist.
	local active_patterns = {}
	local active_negate_count = 0
	if M.config.respect_ignore and ancestor_patterns then
		for _, p in ipairs(ancestor_patterns) do
			active_patterns[#active_patterns + 1] = p
			if p.negate then
				active_negate_count = active_negate_count + 1
			end
		end
	end

	_p_start("setup_ignore")
	-- Read the root directory's own .ignore / .gitignore before descending.
	-- Uses the already-populated by_parent map instead of fs_stat to avoid
	-- synchronous stat syscalls — find(1) already listed these files.
	-- (emit_children handles ignore files inside each subdirectory.)
	if M.config.respect_ignore then
		local root_children = by_parent[dir]
		if root_children then
			for _, child in ipairs(root_children) do
				if child.name == ".ignore" or child.name == ".gitignore" then
					local local_patterns = parse_ignore_file(child.path)
					for _, p in ipairs(local_patterns) do
						active_patterns[#active_patterns + 1] = { raw = p.raw, negate = p.negate, source_dir = dir }
						if p.negate then
							active_negate_count = active_negate_count + 1
						end
					end
				end
			end
		end
	end

	_p_end() -- setup_ignore
	-- DFS traversal: build the flat result list with indent levels,
	-- reading .ignore/.gitignore files on the way down and tagging
	-- hidden entries using the active pattern stack.
	local result = {}

	---@param parent_path   string  the directory whose children to emit
	---@param depth         number  indent level for these children
	---@param inside_hidden boolean true when an ancestor directory is hidden
	local function emit_children(parent_path, depth, inside_hidden)
		local children = by_parent[parent_path]
		if not children then
			return
		end

		for _, entry in ipairs(children) do
			entry.indent = depth

			-- Tag hidden entries using the active pattern stack.
			-- .ignore itself is never tagged as hidden.
			if entry.name ~= ".ignore" then
				if inside_hidden then
					-- All descendants of a hidden directory inherit the tag;
					-- skip the expensive matches_ignore call for the whole subtree.
					entry.is_hidden = true
				else
					local is_dotfile = entry.name:sub(1, 1) == "."
					if is_dotfile then
						-- Dotfiles are always hidden — short-circuit before matches_ignore.
						entry.is_hidden = true
					elseif
						M.config.respect_ignore
						and #active_patterns > 0
						and matches_ignore(
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
			end

			result[#result + 1] = entry

			if entry.type == "dir" then
				-- Push this directory's .ignore / .gitignore patterns.
				-- Track the count so we can pop them exactly after recursion.
				local pushed = 0
				if M.config.respect_ignore then
					-- Look up .ignore / .gitignore in the already-populated
					-- by_parent map instead of calling fs_stat, avoiding
					-- synchronous stat syscalls on every directory.
					local dir_children = by_parent[entry.path]
					if dir_children then
						for _, child in ipairs(dir_children) do
							if child.name == ".ignore" or child.name == ".gitignore" then
								local local_patterns = parse_ignore_file(child.path)
								for _, p in ipairs(local_patterns) do
									pushed = pushed + 1
									active_patterns[#active_patterns + 1] =
										{ raw = p.raw, negate = p.negate, source_dir = entry.path }
									if p.negate then
										active_negate_count = active_negate_count + 1
									end
								end
							end
						end
					end
				end
				-- Recurse, carrying forward whether we're inside a hidden tree.
				emit_children(entry.path, depth + 1, inside_hidden or entry.is_hidden)
				-- Pop exactly the patterns we pushed so the stack is correct
				-- for sibling entries.
				for _ = 1, pushed do
					if active_patterns[#active_patterns].negate then
						active_negate_count = active_negate_count - 1
					end
					active_patterns[#active_patterns] = nil
				end
			end
		end
	end

	_p_start("dfs_emit")
	emit_children(dir, current_depth, false)
	_p_end() -- dfs_emit

	_p_end()
	return result
end

----------------------------------------------------------------------
-- fd-based scanner (fast path) — respects .gitignore/.ignore and skips
-- hidden entries natively, so we never walk .git/node_modules/ignored
-- trees.  Falls back to read_dir_recursive when fd is unavailable.
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

--- Scan `dir` with fd, returning a flat DFS-ordered entry list with the
--- same shape read_dir_recursive produces: { name, type, path, indent,
--- is_hidden? }.  fd natively skips .git/ contents and respects
--- .gitignore/.ignore, so we never traverse giant ignored subtrees.
--- A single fd pass replaces the old find + fd dual scan.
--- Symlinks are never followed — they appear as atomic entries (type "link").
---@param dir         string
---@param show_hidden boolean
---@param depth?      number  starting indent (0 for the root call)
---@return table[]
local function scan_fd(dir, show_hidden, depth)
	_p_start("scan_fd")
	depth = depth or 0

	-- Build fd flags.  fd natively skips .git/ contents (hardcoded ignore).
	-- -H includes hidden (dot) files and directories.
	-- -I disables .gitignore/.ignore filtering — needed when show_hidden is
	--    true (so .venv/, node_modules/ etc. appear as dimmed entries) or
	--    when the user has set respect_ignore = false.
	local fd_flags = { "--color", "never" }
	if show_hidden then
		fd_flags[#fd_flags + 1] = "-H"
	end
	if show_hidden or not M.config.respect_ignore then
		fd_flags[#fd_flags + 1] = "-I"
	end

	-- Main scan: get all entries.  fd appends "/" to directories so
	-- we can infer type without a separate stat call.
	_p_start("fd_scan")
	local main_cmd = { fd_cmd() }
	vim.list_extend(main_cmd, fd_flags)
	main_cmd[#main_cmd + 1] = "."
	main_cmd[#main_cmd + 1] = dir
	local fd_out = vim.fn.systemlist(main_cmd)
	_p_end() -- fd_scan

	-- Symlink scan: fd -t l lists only symlinks.  We build a set so
	-- emit() can tag them as type "link" and follow dir targets.
	_p_start("fd_scan_links")
	local symlink_set = {}
	local link_cmd = { fd_cmd() }
	vim.list_extend(link_cmd, fd_flags)
	link_cmd[#link_cmd + 1] = "-t"
	link_cmd[#link_cmd + 1] = "l"
	link_cmd[#link_cmd + 1] = "."
	link_cmd[#link_cmd + 1] = dir
	local link_out = vim.fn.systemlist(link_cmd)
	if type(link_out) == "table" then
		for _, p in ipairs(link_out) do
			if p ~= "" then
				if p:sub(-1) == "/" then
					p = p:sub(1, -2)
				end
				symlink_set[p] = true
			end
		end
	end
	_p_end() -- fd_scan_links

	_p_start("parse_fd_output")
	local by_parent = {}
	if type(fd_out) == "table" then
		for _, raw in ipairs(fd_out) do
			if raw == "" then
				goto next_entry
			end
			local is_dir = raw:sub(-1) == "/"
			local full = is_dir and raw:sub(1, -2) or raw

			-- Infer type: symlink set wins, else dir by trailing /, else file.
			local etype
			if symlink_set[full] then
				etype = "link"
			elseif is_dir then
				etype = "dir"
			else
				etype = "file"
			end

			-- Split full path into parent dir and basename.
			-- e.g. /root/src/main.lua -> parent=/root/src, name=main.lua
			local parent, name = full:match("^(.*)/(.+)$")
			if not parent then
				parent = dir
				name = full
			end

			local lst = by_parent[parent]
			if not lst then
				lst = {}
				by_parent[parent] = lst
			end
			lst[#lst + 1] = { name = name, type = etype, path = full }
			::next_entry::
		end
	end
	_p_end() -- parse_fd_output

	_p_start("sort_children")
	for _, children in pairs(by_parent) do
		sort_children(children)
	end
	_p_end() -- sort_children

	-- Tag hidden entries: an entry is hidden when its name starts with
	-- ".".  Since fd already filters gitignored entries (when
	-- respect_ignore is true), no per-entry ignore-pattern matching is
	-- needed here.  No second fd call -- the old visible_set approach is
	-- gone.
	local result = {}
	local function emit(parent, d)
		local children = by_parent[parent]
		if not children then
			return
		end
		for _, e in ipairs(children) do
			e.indent = d
			if show_hidden and e.name:sub(1, 1) == "." then
				e.is_hidden = true
			end
			result[#result + 1] = e
			if e.type == "dir" then
				emit(e.path, d + 1)
			end
			-- Symlinks are never followed — they appear as atomic entries.
		end
	end
	emit(dir, depth)

	_p_end()
	return result
end

--- Dispatch to the fd scanner when available, else the find fallback.
--- Both return the same flat entry-list shape.
---@param dir string
---@return table[]
local function scan_tree(dir)
	if fd_cmd() then
		return scan_fd(dir, M.config.show_hidden)
	end
	return read_dir_recursive(dir)
end

--- Build the display line for an entry. Directories get a trailing slash.
---@param entry  table  { name, type, path, indent? }
---@return string
local function format_line(entry)
	local prefix = indent_str(entry.indent or 0)
	local suffix = entry.type == "dir" and "/" or (entry.type == "link" and "@" or "")
	-- Escape control characters so nvim_buf_set_lines doesn't reject the line.
	-- Uses shell $'...' notation so the original name can be recovered.
	local name = entry.name:gsub("[\n\r\t]", function(c)
		return ({ ["\n"] = "$'\\n'", ["\r"] = "$'\\r'", ["\t"] = "$'\\t'" })[c]
	end)
	return prefix .. name .. suffix
end

--- Parse a display line: strip leading whitespace, detect trailing-slash dir
--- marker and trailing-@ symlink marker.
---@param line string
---@return string name      cleaned name (no indent, no trailing / or @)
---@return boolean is_dir   true if the line ends with "/"
---@return boolean is_link  true if the line ends with "@"
local function parse_line(line)
	local name = line:match("^%s*(.+)") or ""
	local is_dir = name:sub(-1) == "/"
	local is_link = name:sub(-1) == "@" and not is_dir
	if is_dir or is_link then
		name = name:sub(1, -2)
	end
	-- Reverse the $'...' escaping applied in format_line.
	name = name:gsub("%$'\\n'", "\n"):gsub("%$'\\r'", "\r"):gsub("%$'\\t'", "\t")
	return name, is_dir, is_link
end

----------------------------------------------------------------------
-- Buffer parser — derives structured entries from the raw buffer text
----------------------------------------------------------------------

--- Parse the entire buffer in one pass, computing the full filesystem
--- path for every entry via an indent stack.  No persistent state needed.
---@param buf number
---@return table[]  list of { name, type, path, indent, lnum }
local function parse_buffer(buf)
	_p_start("parse_buffer")
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local root = vim.b[buf].filebuf_root
	local entries = {}

	-- Stack of { indent, path } — the ancestry chain.  A directory pushes
	-- onto the stack; when indent decreases we pop until the top is a true
	-- ancestor (indent < current).
	local stack = {} -- { indent = number, path = string }

	for lnum = 1, #lines do
		local line = lines[lnum]
		if line == "" then
			goto continue
		end

		local name, is_dir, is_link = parse_line(line)
		if name == "" then
			goto continue
		end

		local indent = indent_level(line)

		-- Fast path: most entries have no "/" in their name.
		-- Avoid the gmatch split and multi-part loop for the common case.
		if not name:find("/", 1, true) then
			while #stack > 0 and stack[#stack].indent >= indent do
				table.remove(stack)
			end

			local parent = #stack > 0 and stack[#stack].path or root
			local part_path = parent .. "/" .. name

			if is_dir then
				table.insert(stack, { indent = indent, path = part_path })
			end

			table.insert(entries, {
				name = name,
				type = is_dir and "dir" or (is_link and "link" or "file"),
				path = part_path,
				indent = indent,
				lnum = lnum,
			})
		else
			-- Split name on "/" so that "dir/subfile" expands into a synthetic
			-- dir entry and a child entry.  Intermediate segments are always
			-- directories; only the final segment inherits the trailing-slash
			-- flag from the line.
			local name_parts = {}
			for part in name:gmatch("[^/]+") do
				name_parts[#name_parts + 1] = part
			end
			if #name_parts == 0 then
				goto continue
			end

			for i, part in ipairs(name_parts) do
				local part_is_dir = (i < #name_parts) or is_dir
				local part_indent = indent + (i - 1)

				while #stack > 0 and stack[#stack].indent >= part_indent do
					table.remove(stack)
				end

				local parent = #stack > 0 and stack[#stack].path or root
				local part_path = parent .. "/" .. part

				if part_is_dir then
					table.insert(stack, { indent = part_indent, path = part_path })
				end

				table.insert(entries, {
					name = part,
					type = part_is_dir and "dir" or (is_link and "link" or "file"),
					path = part_path,
					indent = part_indent,
					lnum = lnum,
				})
			end
		end
	::continue::
	end

	_p_end()
	return entries
end

----------------------------------------------------------------------
-- Diff engine — compares buffer entries against on-disk state
----------------------------------------------------------------------

--- Compare the buffer's desired state with the actual filesystem and
--- produce a set of operations that would bring the disk in line with
--- the buffer.
---
--- Rename detection is name-based: an unmatched buffer entry is paired
--- with an unmatched disk entry that shares the same name, preferring a
--- match in the same parent directory.
---
---@param buf_entries  table[]  parsed buffer entries (from parse_buffer)
---@param disk_entries  table[]  entries from read_dir_recursive
---@return table  { unchanged, renamed, created, deleted, errors }
local function compute_diff(buf_entries, disk_entries)
	_p_start("compute_diff")
	-- Index disk entries by path for O(1) lookup
	local disk_by_path = {}
	for _, de in ipairs(disk_entries) do
		disk_by_path[de.path] = de
	end

	local unchanged = {}
	local renamed = {} -- { old = disk_entry, new = buf_entry }
	local created = {}
	local deleted = {}
	local errors = {}

	local consumed = {} -- set of disk paths already matched

	------------------------------------------------------------------
	-- Phase 1: exact-path match -------------------------------------
	------------------------------------------------------------------
	local buf_unmatched = {}
	for _, be in ipairs(buf_entries) do
		local de = disk_by_path[be.path]
		if de then
			if (de.type == "dir") ~= (be.type == "dir") then
				-- Type mismatch on an otherwise-unchanged entry.
				-- e.g. user accidentally deleted the trailing "/" from a dir,
				-- or added "/" to a file.
				local detail = be.type == "dir" and " (extra trailing '/')" or " (missing trailing '/')"
				table.insert(errors, {
					lnum = be.lnum,
					message = string.format(
						"'%s' is a %s on disk but shown as %s in buffer%s",
						be.name,
						de.type,
						be.type,
						detail
					),
				})
			end
			table.insert(unchanged, be)
			consumed[de.path] = true
		else
			table.insert(buf_unmatched, be)
		end
	end

	------------------------------------------------------------------
	-- Phase 2: name-based rename matching ---------------------------
	------------------------------------------------------------------

	-- Collect unmatched disk entries
	local disk_unmatched = {}
	for _, de in ipairs(disk_entries) do
		if not consumed[de.path] then
			table.insert(disk_unmatched, de)
		end
	end

	-- Index unmatched disk entries by name
	local disk_by_name = {}
	for _, de in ipairs(disk_unmatched) do
		if not disk_by_name[de.name] then
			disk_by_name[de.name] = {}
		end
		table.insert(disk_by_name[de.name], de)
	end

	local renamed_disk_paths = {} -- set of disk paths consumed by renames
	for _, be in ipairs(buf_unmatched) do
		local candidates = disk_by_name[be.name]
		if candidates then
			-- Prefer same-parent matches to avoid false positives when
			-- multiple directories contain files with the same name.
			local best = nil
			local be_parent = vim.fn.fnamemodify(be.path, ":h")
			for _, de in ipairs(candidates) do
				if not renamed_disk_paths[de.path] then
					local de_parent = vim.fn.fnamemodify(de.path, ":h")
					if de_parent == be_parent then
						best = de
						break
					end
				end
			end
			-- Fallback: any unmatched disk entry with the same name
			if not best then
				for _, de in ipairs(candidates) do
					if not renamed_disk_paths[de.path] then
						best = de
						break
					end
				end
			end

			if best then
				if (best.type == "dir") ~= (be.type == "dir") then
					table.insert(errors, {
						lnum = be.lnum,
						message = string.format(
							"'%s' rename changes type: %s on disk -> %s in buffer",
							be.name,
							best.type,
							be.type
						),
					})
				end
				table.insert(renamed, { old = best, new = be })
				renamed_disk_paths[best.path] = true
			else
				table.insert(created, be)
			end
		else
			table.insert(created, be)
		end
	end

	------------------------------------------------------------------
	-- Phase 3: remaining disk entries are deletes -------------------
	------------------------------------------------------------------
	for _, de in ipairs(disk_unmatched) do
		if not renamed_disk_paths[de.path] then
			table.insert(deleted, de)
		end
	end

	_p_end()
	return {
		unchanged = unchanged,
		renamed = renamed,
		created = created,
		deleted = deleted,
		errors = errors,
	}
end

----------------------------------------------------------------------
-- Operation applicator — executes the diff results on the filesystem
----------------------------------------------------------------------

--- Report validation errors via vim.diagnostic (inline markers) and a
--- single vim.notify summary.
---@param buf    number
---@param errors table[]  { lnum, message }
local function report_errors(buf, errors)
	vim.diagnostic.reset(nil, buf)
	if #errors == 0 then
		return
	end

	local diags = {}
	for _, err in ipairs(errors) do
		table.insert(diags, {
			lnum = (err.lnum or 1) - 1, -- 0-indexed
			col = 0,
			severity = vim.diagnostic.severity.ERROR,
			message = err.message,
			source = "filebuf",
		})
	end
	vim.diagnostic.set(nil, buf, diags)
	vim.notify(string.format("filebuf: %d error(s) — fix and save again", #errors), vim.log.levels.ERROR)
end

--- Apply the computed operations to the filesystem.
---
--- Execution order:
---   1. Renames — move files before their source directories are deleted.
---      Target parent directories are created first when needed.
---   2. Deletes — deepest path first (children before parents).
---   3. Creates — sorted by depth (shallowest first) with `mkdir -p`
---      semantics so intermediate directories are always created
---      automatically.
---@param ops table  result of compute_diff()
local function apply_ops(ops)
	-- 1. Renames (before deletes so source files are moved out before
	--    their parent dirs are recursively removed).
	for _, r in ipairs(ops.renamed) do
		-- Ensure the target parent directory exists before renaming.
		local target_parent = vim.fn.fnamemodify(r.new.path, ":h")
		vim.fn.mkdir(target_parent, "p")
		local ok, err = pcall(vim.loop.fs_rename, r.old.path, r.new.path)
		if not ok then
			vim.notify("filebuf: cannot rename – " .. (err or r.old.path), vim.log.levels.ERROR)
		end
	end

	-- 2. Deletes (deepest first)
	local to_delete = {}
	for _, de in ipairs(ops.deleted) do
		table.insert(to_delete, de)
	end
	table.sort(to_delete, function(a, b)
		return #a.path > #b.path
	end)

	-- When permanent_delete is disabled, prepare a timestamped trash
	-- directory so that every save gets its own recovery folder.
	local trash_dir = nil
	if not M.config.permanent_delete and #to_delete > 0 then
		trash_dir = string.format("/tmp/filebuf-trash/%s", os.date("%Y_%m_%d_%H_%M_%S"))
		vim.fn.mkdir(trash_dir, "p")
	end

	for _, de in ipairs(to_delete) do
		if trash_dir then
			-- Move to trash instead of deleting.
			local dest = trash_dir .. "/" .. de.name
			-- Avoid name collisions inside the trash folder.
			local n = 1
			while vim.loop.fs_stat(dest) do
				n = n + 1
				dest = string.format("%s/%s.%d", trash_dir, de.name, n)
			end
			local ok, err = pcall(vim.loop.fs_rename, de.path, dest)
			if not ok then
				vim.notify("filebuf: cannot trash – " .. (err or de.path), vim.log.levels.ERROR)
			end
		elseif de.type == "dir" then
			pcall(vim.fn.delete, de.path, "rf")
		else
			pcall(vim.loop.fs_unlink, de.path)
		end
	end

	-- 3. Creates — sort by depth so parents are always created before
	--    children, and ensure every parent directory exists.
	table.sort(ops.created, function(a, b)
		local na = select(2, a.path:gsub("/", "/"))
		local nb = select(2, b.path:gsub("/", "/"))
		if na ~= nb then
			return na < nb -- shallower paths first
		end
		-- Directories before files at the same depth
		return a.type == "dir" and b.type ~= "dir"
	end)
	for _, be in ipairs(ops.created) do
		if be.type == "dir" then
			-- "p" flag creates intermediate directories (mkdir -p).
			local ok, err = pcall(vim.fn.mkdir, be.path, "p")
			if not ok then
				vim.notify("filebuf: cannot create dir – " .. (err or be.path), vim.log.levels.ERROR)
			end
		else
			-- Ensure the parent directory chain exists before creating the file.
			local parent_dir = vim.fn.fnamemodify(be.path, ":h")
			vim.fn.mkdir(parent_dir, "p")
			local fd, err = vim.loop.fs_open(be.path, "w", 420) -- 0644
			if not fd then
				vim.notify("filebuf: cannot create file – " .. (err or be.path), vim.log.levels.ERROR)
			else
				vim.loop.fs_close(fd)
			end
		end
	end
end

----------------------------------------------------------------------
-- Buffer manipulation
----------------------------------------------------------------------

--- Insert `entries` into `buf` after `after_line`.  Indent is taken
--- from each entry's `.indent` field (set by read_dir_recursive).
--- Returns the number of lines inserted.
---@param buf        number
---@param entries    table[]
---@param after_line number  0-indexed line to insert after (0 = top)
---@return number
local function insert_entries(buf, entries, after_line)
	local lines = {}
	for _, entry in ipairs(entries) do
		table.insert(lines, format_line(entry))
	end
	vim.api.nvim_buf_set_lines(buf, after_line, after_line, false, lines)
	return #lines
end

--- Create manual folds so that each directory line *includes* its
--- descendants (not just the children).  Nested directories get their
--- own inner folds.
---
--- Uses a single-pass stack-based algorithm (O(n)) instead of scanning
--- all entries per directory (O(n²)).  Directories are pushed onto a
--- stack when encountered; when an entry at ≤ indent arrives, the
--- directory on top of the stack has ended and its fold is emitted.
--- Because the stack is LIFO, inner folds are always emitted before
--- outer ones, which is required by Neovim's manual-fold model.
---
---@param buf     number
---@param entries? table[]  pre-parsed entries (avoids redundant parse_buffer)
local function create_folds(buf, entries)
	_p_start("create_folds")
	entries = entries or parse_buffer(buf)
	if #entries == 0 then
		_p_end()
		return
	end

	local stack = {} -- { lnum = number, indent = number }
	local prev = nil -- last entry processed (used as fold endpoint)
	local cmds = {} -- batched fold commands

	for _, e in ipairs(entries) do
		-- Pop directories whose scope has ended: when the current entry's
		-- indent is back at or above the directory's own indent, we've left
		-- that directory's subtree.  The previous entry (if deeper) is the
		-- last descendant and becomes the fold's end line.
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

	-- Close any directories that extend to the end of the buffer.
	while #stack > 0 do
		local d = table.remove(stack)
		if prev and prev.indent > d.indent and prev.lnum > d.lnum then
			cmds[#cmds + 1] = string.format("%d,%dfold", d.lnum, prev.lnum)
		end
	end

	-- Execute all fold commands in one batch.  Inner folds are emitted
	-- first (they're popped from the top of the LIFO stack), satisfying
	-- Neovim's requirement that nested folds be created inside-out.
	if #cmds > 0 then
		vim.cmd(table.concat(cmds, "|"))
	end

	_p_end()
end

--- Custom fold-text callback (called via v:lua.FilebufFoldText).
--- Shows the cleaned entry name and the count of folded lines.
--- Uses strdisplaywidth to convert the line's leading whitespace into an
--- equivalent number of space characters, so the fold text always visually
--- aligns with the unfolded lines regardless of tabstop.
function _G.FilebufFoldText()
	local line = vim.fn.getline(vim.v.foldstart)
	local indent_ws = line:match("^(%s*)") or ""
	local name = line:match("^%s*(.-)%s*$") or line
	local indent = string.rep(" ", vim.fn.strdisplaywidth(indent_ws))
	return indent .. name
end

----------------------------------------------------------------------
-- Git status indicators (extmarks)
----------------------------------------------------------------------

--- Namespace for all filebuf decorations (git status, directory highlight,
--- hidden-file dimming).  Managed by the decoration provider registered in
--- setup(), not by manual nvim_buf_set_extmark / nvim_buf_clear_namespace.
local deco_ns = vim.api.nvim_create_namespace("filebuf-deco")

--- Define highlight groups for git statuses.  `default = true` ensures
--- user overrides in their colorscheme take precedence.
local function define_git_highlights()
	local groups = {
		FilebufGitAdded = { fg = "#98c379" },
		FilebufGitModified = { fg = "#e5c07b" },
		FilebufGitDeleted = { fg = "#e06c75" },
		FilebufGitUntracked = { fg = "#61afef" },
		FilebufGitConflict = { fg = "#c678dd" },
		FilebufGitRenamed = { fg = "#56b6c2" },
	}
	for name, def in pairs(groups) do
		vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", def, { default = true }))
	end
end

--- Unquote a path from git status --porcelain output.  Git wraps
--- paths that contain special characters (spaces, tabs, newlines,
--- non-ASCII bytes, etc.) in double quotes and uses C-style escaping
--- (\n, \t, \\, \") inside them.
---@param path string
---@return string
local function unquote_git_path(path)
	if path:sub(1, 1) == '"' and path:sub(-1) == '"' then
		path = path:sub(2, -2)
		path = path:gsub("\\n", "\n")
		path = path:gsub("\\t", "\t")
		path = path:gsub("\\r", "\r")
		path = path:gsub('\\"', '"')
		path = path:gsub("\\\\", "\\")
	end
	return path
end

--- Run `git status --porcelain` in `root` and return a map of
--- filesystem path → { index, worktree } status codes.
--- Returns nil when the directory is not inside a git repo or git is
--- not available.
---@param root string
---@return table|nil
local function get_git_status_map(root)
	_p_start("get_git_status_map")
	local cmd =
		string.format("git -C %s status --porcelain --ignored=matching --untracked-files=all", vim.fn.shellescape(root))
	local output = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		_p_end()
		return nil
	end

	local status_map = {}
	for line in output:gmatch("[^\r\n]+") do
		local x = line:sub(1, 1)
		local y = line:sub(2, 2)
		local filename = unquote_git_path(line:sub(4))

		-- Handle renames: "R  old -> new"
		-- The "->" arrow and both paths may be quoted separately when
		-- either path contains special characters, e.g.
		-- R  "old path" -> "new path"
		if x == "R" then
			local arrow = filename:find(" -> ")
			if arrow then
				filename = filename:sub(arrow + 4)
			end
			-- Unquote again for the new-name portion in case it was
			-- individually quoted inside the combined rename string.
			filename = unquote_git_path(filename)
		end

		local path = root .. "/" .. filename
		status_map[path] = { index = x, worktree = y }
	end

	_p_end()
	return status_map
end

--- Convert a git-porcelain status pair to a display character and
--- highlight-group name.  Worktree status takes priority over index
--- status because it reflects the current on-disk state.
---@param s table  { index, worktree }
---@return string|nil char      single-letter status indicator
---@return string|nil hl_group
local function porcelain_to_display(s)
	local x, y = s.index, s.worktree

	-- Worktree status > index status
	local code
	if y ~= " " then
		code = y
	elseif x ~= " " then
		code = x
	else
		return nil
	end

	if code == "?" then
		return "U", "FilebufGitUntracked"
	end
	if code == "A" then
		return "A", "FilebufGitAdded"
	end
	if code == "M" then
		return "M", "FilebufGitModified"
	end
	if code == "D" then
		return "D", "FilebufGitDeleted"
	end
	if code == "R" then
		return "R", "FilebufGitRenamed"
	end
	if code == "U" then
		return "C", "FilebufGitConflict"
	end

	return nil
end

--- Look up the git status for a single entry.
--- Only returns a status for entries that appear directly in git-status
--- output (i.e. files with changes).  Directory names are not colored by
--- git status — the Directory highlight group always wins.
---@param entry table       parsed buffer entry
---@param status_map table  map from get_git_status_map
---@return string|nil char
---@return string|nil hl_group
local function get_entry_git_status(entry, status_map)
	if not status_map then
		return nil
	end

	-- Direct match: the entry's path appears verbatim in git status.
	-- Directories only appear in rare cases (e.g. untracked dirs); for
	-- those we still show the status indicator but don't change the name
	-- color (handled in the decoration provider).
	local s = status_map[entry.path]
	if s then
		return porcelain_to_display(s)
	end

	return nil
end

----------------------------------------------------------------------
-- Decoration provider — replaces manual extmark management.
-- Registered once in setup(); Neovim calls on_win on every redraw
-- (scroll, fold toggle, buffer change, window resize), so we never
-- need to manually clear or refresh extmarks.
----------------------------------------------------------------------

--- on_start callback: skip the entire redraw cycle when no filebuf
--- window is visible, avoiding unnecessary work.
local function deco_on_start()
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(winid)
		if vim.b[buf].filebuf_root then
			return true -- at least one filebuf window, proceed
		end
	end
	return false -- nothing to decorate this cycle
end

--- on_win callback: apply ephemeral dir, hidden, and git extmarks to
--- the lines currently visible in the window.  Fold-aware — the interior
--- of closed folds is skipped so cost stays O(screen) regardless of
--- buffer size.
---
--- Priorities: dir (10) > hidden (5) > git (0).
--- All extmarks use ephemeral=true so they auto-expire after the redraw.
---@param _      string  "win"
---@param winid  integer
---@param bufnr  integer
---@param toprow integer  screen row (unused — we derive buffer coords)
---@param botrow integer  screen row (unused)
local function deco_on_win(_, winid, bufnr, toprow, botrow)
	-- Only handle filebuf windows.
	if not vim.b[bufnr].filebuf_root then
		return false
	end

	-- Resolve entries for visible lines.  Normally the cached
	-- display list (1:1 with buffer lines) is reused, but when
	-- the buffer has been edited the cache is stale — a re-parse
	-- of the buffer text produces a fresh lnum→entry map instead.
	-- is_hidden is recovered from the full-entry cache so dimming
	-- still works during edits.
	local entries
	if vim.bo[bufnr].modified then
		local parsed = parse_buffer(bufnr)
		entries = {}
		for _, e in ipairs(parsed) do
			entries[e.lnum] = e
		end
		-- Recover is_hidden from the full-entry cache (not in buffer text).
		local all = vim.b[bufnr].filebuf_all_entries
		if all then
			local by_path = {}
			for _, e in ipairs(all) do
				by_path[e.path] = e
			end
			for _, e in pairs(entries) do
				local cached = by_path[e.path]
				if cached then
					e.is_hidden = cached.is_hidden
				end
			end
		end
	else
		entries = vim.b[bufnr].filebuf_display_entries
	end
	if not entries then
		return false
	end


	-- Pre-compute helpers reused across every visible line.
	local height = vim.api.nvim_win_get_height(winid)
	local use_tabs = not vim.go.expandtab
	local iw = indent_width()
	local status_map = M.config.git_status and vim.b[bufnr].filebuf_git_status or nil

	-- Walk visible buffer lines, skipping the interior of closed folds.
	local lnum = toprow + 1  -- toprow is 0-indexed, entries is 1-indexed
	local count = 0
	while lnum <= botrow + 1 and count <= height + 2 do
		local entry = entries[lnum]
		if entry then
			local name_start = use_tabs and entry.indent or (entry.indent * iw)
			local suffix = (entry.type == "dir" or entry.type == "link") and 1 or 0 -- trailing "/" or "@"
			local name_end = name_start + #entry.name + suffix

			-- Directory highlight (priority 10 — highest).
			if entry.type == "dir" then
				vim.api.nvim_buf_set_extmark(bufnr, deco_ns, lnum - 1, name_start, {
					end_col = name_end,
					hl_group = "Directory",
					priority = 10,
					ephemeral = true,
				})
			end

			-- Symlink highlight (priority 8 — under dir, above hidden/git).
			if entry.type == "link" then
				vim.api.nvim_buf_set_extmark(bufnr, deco_ns, lnum - 1, name_start, {
					end_col = name_end,
					hl_group = "FilebufLink",
					priority = 8,
					ephemeral = true,
				})
			end

			-- Hidden / dimmed (priority 5 — overrides git color, under dir).
			if entry.is_hidden then
				local hl = entry.type == "dir" and "FilebufHiddenDir" or "FilebufHiddenFile"
				vim.api.nvim_buf_set_extmark(bufnr, deco_ns, lnum - 1, name_start, {
					end_col = name_end,
					hl_group = hl,
					priority = 5,
					ephemeral = true,
				})
			end

			-- Git status (priority 0 — lowest; dirs get virt_text only, no name color).
			if status_map then
				local char, hl = get_entry_git_status(entry, status_map)
				if char then
					local extmark_opts = {
						virt_text = { { " " .. char, hl } },
						priority = 0,
						ephemeral = true,
            end_col = -1
					}
					if entry.type ~= "dir" then
						extmark_opts.hl_group = hl
					end
					vim.api.nvim_buf_set_extmark(bufnr, deco_ns, lnum - 1, name_start, extmark_opts)
				end
			end
		end

		count = count + 1
		local fold_end = vim.fn.foldclosedend(lnum)
		if fold_end ~= -1 then
			lnum = fold_end + 1
		else
			lnum = lnum + 1
		end
	end

	return false -- no on_line / on_range needed; all work is done here
end

local function define_filebuf_type_highlights()
	local groups = {
		FilebufHiddenFile = { fg = "#5c6370" },
		FilebufHiddenDir = { fg = "#5c6370" },
			FilebufLink = { fg = "#56b6c2" }, -- cyan to distinguish from Directory (blue)
	}
	for name, def in pairs(groups) do
		vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", def, { default = true }))
	end
end

--- Create FilebufFoldLine: Directory's foreground on Normal's background.
--- This is used by winhighlight to override Folded on the filebuf window.
--- A plain link to Directory doesn't work because winhighlight overlays
--- attributes — Directory typically sets only fg (bg=NONE), so Folded's
--- background would leak through.  By resolving Directory's fg and Normal's
--- bg at setup time we give winhighlight a group that fully replaces both.
local function define_filebuf_highlights()
	-- nvim_get_hl is available since Neovim 0.9
	if not pcall(vim.api.nvim_get_hl, 0, { name = "Normal" }) then
		-- Fallback for older Neovim: plain link (may still leak bg,
		-- but better than nothing).
		vim.api.nvim_set_hl(0, "FilebufFoldLine", { link = "Directory", default = true })
		return
	end

	local function hl_attr(name, attr)
		local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name })
		return ok and hl and hl[attr] or nil
	end

	local dir_fg = hl_attr("Directory", "fg")
	local normal_bg = hl_attr("Normal", "bg")

	if dir_fg or normal_bg then
		local attrs = { default = true }
		if dir_fg then
			attrs.fg = dir_fg
		end
		if normal_bg then
			attrs.bg = normal_bg
		end
		vim.api.nvim_set_hl(0, "FilebufFoldLine", attrs)
	else
		vim.api.nvim_set_hl(0, "FilebufFoldLine", { link = "Directory", default = true })
	end
end

----------------------------------------------------------------------
-- <CR> handler
----------------------------------------------------------------------

--- Persist the closed-fold set for `dir` by scanning the current buffer.
---@param buf     number
---@param root    string  root directory (key into M._fold_closed)
---@param entries? table[] pre-parsed buffer entries (avoids redundant parse)
local function save_fold_state(buf, root, entries)
	M._fold_closed[root] = {}
	-- Use the cached display entries (1:1 with buffer lines, each carrying
	-- lnum) — no need to re-parse the buffer text for a read-only scan.
	entries = entries or vim.b[buf].filebuf_display_entries or {}
	for _, e in ipairs(entries) do
		if e.type == "dir" and vim.fn.foldclosed(e.lnum) ~= -1 then
			M._fold_closed[root][e.path] = true
		end
	end
end

--- Handle <CR> in the filebuf buffer.
local function handle_enter(buf)
	local lnum = vim.api.nvim_win_get_cursor(0)[1]

	-- Resolve the entry at the cursor from the cached display entries
	-- (1:1 with buffer lines) — no need to re-parse the buffer text.
	local entries = vim.b[buf].filebuf_display_entries
	local entry = entries and entries[lnum]
	if not entry then
		return
	end

	if entry.type == "dir" then
		-- Toggle the indent-based fold at this line.  The decoration
		-- provider (deco_on_win) fires on the redraw triggered by zo/zc,
		-- so newly-revealed lines are coloured automatically.
		vim.api.nvim_win_set_cursor(0, { lnum, 0 })
		local fold_end = vim.fn.foldclosedend(lnum)
		if fold_end ~= -1 then
			vim.cmd("normal! zo")
		else
			vim.cmd("normal! zc")
		end
		-- Immediately persist the new fold state so it survives
		-- close / reopen and subsequent saves.
		save_fold_state(buf, vim.b[buf].filebuf_root)
	else
		-- File, symlink->file: open for editing. Symlink->dir: open new filebuf.
		local target = vim.loop.fs_realpath(entry.path) or entry.path
		if entry.type == "link" and vim.fn.isdirectory(target) == 1 then
			-- Symlink to directory: open a new filebuf at the target.
			M.open(target)
		elseif vim.fn.filereadable(target) == 1 then
			vim.cmd("edit " .. vim.fn.fnameescape(target))
		else
			vim.notify("Cannot read: " .. entry.path, vim.log.levels.WARN)
		end
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

--- Rebuild buffer display from a pre-computed entries list.
--- Handles setting buffer lines, rebuilding folds, restoring
--- previously-open directories, persisting fold state, and applying
--- extmarks.  The entry list MUST correspond 1:1 with the desired
--- buffer lines (i.e. it should already be filtered by filter_visible
--- if hidden entries should be excluded).
---@param buf       number
---@param entries   table[]  display entries (1:1 with buffer lines)
---@param open_dirs table|nil  set of dir paths that should stay open;
---                            when nil, all directories start closed
local function rebuild_buffer_display(buf, entries, open_dirs)
	local dir = vim.b[buf].filebuf_root
	if not dir then
		return
	end

	-- The entries are 1:1 with buffer lines; stamp each with its line
	-- number so folds, fold-state, and extmarks can use them directly
	-- without a redundant parse_buffer pass.
	for i, entry in ipairs(entries) do
		entry.lnum = i
	end

	-- 1. Rebuild buffer lines from entries
	local fresh_lines = {}
	for _, entry in ipairs(entries) do
		table.insert(fresh_lines, format_line(entry))
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, fresh_lines)

	-- 2. Cache the entries so read-only navigation reuses them.
	vim.b[buf].filebuf_buf_entries = entries
	vim.b[buf].filebuf_display_entries = entries

	-- 3. Rebuild folds — create_folds produces closed folds for every
	--    directory.  Then re-open only the directories that were open
	--    before the refresh.
	vim.cmd("silent! normal! zE")
	create_folds(buf, entries)
	for _, e in ipairs(entries) do
		if e.type == "dir" and open_dirs and open_dirs[e.path] then
			vim.cmd(string.format("silent! %dfoldopen", e.lnum))
		end
	end
	-- Persist the updated fold state so it survives a subsequent
	-- close / reopen.  This must happen *after* folds are rebuilt,
	-- otherwise newly-revealed directories (e.g. hidden dirs after
	-- a toggle) are missing from the closed set and would all open
	-- on the next :Filebuf.
	save_fold_state(buf, dir, entries)

	-- 4. Cache git status so the decoration provider picks it up on
	--    the next redraw (nvim_buf_set_lines above triggers one).
	vim.b[buf].filebuf_git_status = get_git_status_map(dir)

	vim.bo[buf].modified = false

	if prof.enabled then
		M.profile_report()
	end
end

--- Re-read the directory tree from disk and refresh the buffer contents.
--- Preserves fold state across the refresh: directories that were open
--- stay open; new directories (e.g. hidden dirs revealed by toggle)
--- remain closed.  Updates the cached full entry list so subsequent
--- toggles can re-filter without touching the filesystem.
---@param buf number  filebuf buffer to refresh
local function refresh_buffer(buf)
	local dir = vim.b[buf].filebuf_root
	if not dir then
		return
	end

	-- 1. Snapshot which directories are currently *open* so we can
	--    restore exactly them after the refresh.  save_fold_state also
	--    persists the closed set so fold preferences survive buffer close.
	save_fold_state(buf, dir)
	local open_dirs = {}
	local pre_entries = vim.b[buf].filebuf_display_entries or {}
	for _, e in ipairs(pre_entries) do
		if e.type == "dir" and vim.fn.foldclosed(e.lnum) == -1 then
			open_dirs[e.path] = true
		end
	end

	-- 2. Re-read the tree from disk (all entries, unfiltered) and cache it.
	local all_entries = scan_tree(dir)
	vim.b[buf].filebuf_all_entries = all_entries
	vim.b[buf].filebuf_has_hidden = M.config.show_hidden

	-- 3. Filter for display and rebuild the buffer.
	rebuild_buffer_display(buf, filter_visible(all_entries), open_dirs)

	if prof.enabled then
		M.profile_report()
	end
end

--- Toggle show_hidden and refresh the filebuf buffer.
--- Refuses if the buffer has unsaved changes to prevent data loss.
--- Preserves the cursor on the same entry across the toggle by resolving
--- the entry path before the refresh and re-locating it afterwards.
---@param buf number
local function toggle_hidden(buf)
	-- Guard: prevent data loss if the user has unsaved edits
	if vim.bo[buf].modified then
		vim.notify("filebuf: save or discard changes before toggling hidden files", vim.log.levels.WARN)
		return
	end

	-- Capture the entry under the cursor before refreshing so we can
	-- restore the cursor to the same entry after the toggle.
	local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
	local pre_entries = vim.b[buf].filebuf_display_entries or {}
	local cursor_entry_path = pre_entries[cursor_lnum] and pre_entries[cursor_lnum].path

	-- Capture which directories are currently open so we can restore
	-- the same state after the toggle.
	local dir = vim.b[buf].filebuf_root
	save_fold_state(buf, dir, pre_entries)
	local open_dirs = {}
	for _, e in ipairs(pre_entries) do
		if e.type == "dir" and vim.fn.foldclosed(e.lnum) == -1 then
			open_dirs[e.path] = true
		end
	end

	M.config.show_hidden = not M.config.show_hidden

	-- Decide whether we can re-filter the cached list in memory or must
	-- re-scan.  filter_visible(full_set) yields the correct view for
	-- either state (it drops hidden entries when show_hidden is false), so:
	--   * hiding            → always re-filter the cache (no scan)
	--   * showing, cache has hidden already → re-filter (no scan)
	--   * showing, cache lacks hidden       → scan once with -H -I, then cache
	-- The heavy hidden scan (which includes .git objects etc.) therefore
	-- runs at most once, not on every toggle.
	local all_entries = vim.b[buf].filebuf_all_entries
	if M.config.show_hidden and not vim.b[buf].filebuf_has_hidden then
		all_entries = scan_tree(dir)
		vim.b[buf].filebuf_all_entries = all_entries
		vim.b[buf].filebuf_has_hidden = true
	end
	all_entries = all_entries or scan_tree(dir)
	rebuild_buffer_display(buf, filter_visible(all_entries), open_dirs)

	-- Re-locate the same entry in the refreshed buffer and move the
	-- cursor to its new line.  This naturally accounts for any entries
	-- that were added or removed before the cursor line by the toggle.
	-- Reuse the buf_entries that rebuild_buffer_display already parsed
	-- and stored, avoiding a redundant parse_buffer call.
	if cursor_entry_path then
		local post_entries = vim.b[buf].filebuf_buf_entries
		for _, e in ipairs(post_entries or {}) do
			if e.path == cursor_entry_path then
				vim.api.nvim_win_set_cursor(0, { e.lnum, 0 })
				break
			end
		end
	end

	local state = M.config.show_hidden and "shown" or "hidden"
	vim.notify("filebuf: hidden files " .. state, vim.log.levels.INFO)
end

--- Open the filebuf browser. The entire directory tree is loaded
--- recursively with indent-based folding.  Top-level entries are visible;
--- subdirectories are initially folded.  Use `za` or `<CR>` (on a
--- directory) to toggle folds.
---
--- Press <CR> on a file to edit it.
---
--- Changes to the buffer are only applied to the filesystem when you
--- save with `:w`.  Type mismatches (e.g. deleting the trailing "/" from
--- a directory) are flagged as errors and block the save.
---
---@param dir string|nil  root directory (default: cwd)
function M.open(dir)
	dir = dir or vim.fn.getcwd()
	-- Normalize: strip trailing slash for consistent path joining.
	dir = dir:gsub("/$", "")

	-- Capture the current editing file *before* we create the filebuf
	-- buffer, so we can auto-focus on it after the tree is built.
	local current_file = vim.api.nvim_buf_get_name(0)

	local buf = vim.api.nvim_create_buf(true, true)
	-- Give the buffer a name so :w triggers BufWriteCmd instead of E32.
	vim.api.nvim_buf_set_name(buf, "filebuf://" .. dir)
	vim.b[buf].filebuf_root = dir
	vim.bo[buf].filetype = "filebuf"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].buftype = "acwrite"

	-- Buffer-local keymaps
	vim.keymap.set("n", "<CR>", function()
		handle_enter(buf)
	end, { buffer = buf, desc = "Open file / toggle directory fold" })
	vim.keymap.set("n", "q", function()
		save_fold_state(buf, dir)
		vim.api.nvim_buf_delete(buf, { force = true })
	end, { buffer = buf, desc = "Close filebuf" })
	vim.keymap.set("n", "H", function()
		toggle_hidden(buf)
	end, { buffer = buf, desc = "Toggle hidden files" })

	-- Populate the buffer with the full recursive tree.
	-- Cache the unfiltered list so toggle_hidden() can re-filter
	-- from memory instead of re-walking the filesystem.
	local all_entries = scan_tree(dir)
	vim.b[buf].filebuf_all_entries = all_entries
	-- Track whether the cached list already contains hidden entries, so
	-- toggle_hidden knows if it can re-filter from memory or must re-scan.
	vim.b[buf].filebuf_has_hidden = M.config.show_hidden
	local display_entries = filter_visible(all_entries)
	-- Entries are 1:1 with buffer lines; stamp line numbers so all
	-- subsequent read-only navigation reuses them without re-parsing.
	for i, e in ipairs(display_entries) do
		e.lnum = i
	end
	if #display_entries > 0 then
		insert_entries(buf, display_entries, 0)
	end

	-- Manual folding: each directory + its descendants form a fold.
	-- Closed initially so only top-level entries are visible.
	vim.api.nvim_set_current_buf(buf)
	vim.wo.foldmethod = "manual"
	vim.wo.foldenable = true
	vim.wo.foldcolumn = "auto:9"
	vim.wo.foldtext = "v:lua.FilebufFoldText()"
	-- Override the Folded highlight group in this window to suppress
	-- the background color (many colorschemes set a prominent bg).
	-- FilebufFoldLine is created at setup time by reading Directory's
	-- fg and Normal's bg.  A plain link to Directory doesn't work
	-- because winhighlight overlays attributes — Directory typically
	-- sets only fg (bg=NONE), so Folded's background would leak through.
	-- FilebufFoldLine has both fg and bg set, fully replacing Folded.
	vim.wo.winhighlight = "Folded:FilebufFoldLine"
	-- Replace default +/- fold-column glyphs with triangles.
	local fc = vim.wo.fillchars or ""
	vim.wo.fillchars = fc .. "foldopen:▼,foldclose:▶,fold: "

	-- Reuse the 1:1 display entries (already carrying lnum) for
	-- create_folds and fold-state restoration — no parse needed.
	local open_entries = display_entries
	create_folds(buf, open_entries)

	-- Restore saved fold state, or close everything on first open.
	if M._fold_closed[dir] then
		-- create_folds already produced closed folds for every directory.
		-- Instead of opening everything and then re-closing, open only the
		-- directories the user had previously expanded (i.e. those missing
		-- from the closed set).  This way any unaccounted directory (e.g. a
		-- newly-revealed hidden dir) defaults to closed instead of open.
		for _, e in ipairs(open_entries) do
			if e.type == "dir" and not M._fold_closed[dir][e.path] then
				vim.cmd(string.format("silent! %dfoldopen", e.lnum))
			end
		end
	else
		-- First open: start with a clean overview.
		vim.cmd("silent! %foldclose!")
	end

	-- Auto-focus on the file that was being edited before :Filebuf.
	if M.config.auto_focus_current_file and current_file ~= "" and vim.startswith(current_file, dir .. "/") then
		local target = vim.fn.resolve(current_file)
		local focus_entries = display_entries
		local target_lnum, target_indent = nil, nil
		for _, e in ipairs(focus_entries) do
			if vim.fn.resolve(e.path) == target then
				target_lnum = e.lnum
				target_indent = e.indent
				break
			end
		end
		if target_lnum and target_indent then
			-- Open ancestor folds from outermost to innermost so the
			-- file is visible.  Collect dirs above the target line whose
			-- indent is less than the target's.
			local ancestors = {}
			for _, e in ipairs(focus_entries) do
				if e.type == "dir" and e.lnum < target_lnum and e.indent < target_indent then
					-- Keep only the closest ancestor at each indent depth
					-- (the last one seen before the target).
					ancestors[e.indent] = e.lnum
				end
			end
			-- Open from outermost (lowest indent) to innermost.
			local sorted = {}
			for _, lnum in pairs(ancestors) do
				table.insert(sorted, lnum)
			end
			table.sort(sorted)
			for _, lnum in ipairs(sorted) do
				pcall(vim.cmd, string.format("%dfoldopen", lnum))
			end
			vim.api.nvim_win_set_cursor(0, { target_lnum, 0 })
			vim.cmd("normal! zz")
		end
	end

	-- Cache display entries and git status so the decoration provider
	-- picks them up on the next redraw.  No manual extmark work needed:
	-- deco_on_win (registered in setup) handles everything.
	vim.b[buf].filebuf_display_entries = display_entries
	vim.b[buf].filebuf_git_status = get_git_status_map(dir)

	-- BufWriteCmd parses the buffer, diffs against the filesystem,
	-- validates, and applies changes.
	local group = vim.api.nvim_create_augroup("filebuf_edit_" .. buf, { clear = true })


	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = group,
		buffer = buf,
		callback = function()
			local ok, result = pcall(function()
				-- 1. Parse the buffer
				local buf_entries = parse_buffer(buf)

				-- 2. Use cached in-memory entries as the baseline disk state
				--    when available (avoids a redundant find call).  Falls
				--    back to a fresh read if the cache is missing.
				local all_disk_entries = vim.b[buf].filebuf_all_entries or scan_tree(dir)
				-- Only consider entries that are visible in the buffer, so
				-- hidden files on disk don't appear as "deleted".
				local disk_entries = filter_visible(all_disk_entries)

				-- 3. Diff
				local ops = compute_diff(buf_entries, disk_entries)

				-- 4. Validate — abort on errors
				if #ops.errors > 0 then
					report_errors(buf, ops.errors)
					error("filebuf: validation failed")
				end

				-- Clear any stale diagnostics from a previous failed save
				vim.diagnostic.reset(nil, buf)

				-- 5. Apply
				apply_ops(ops)

				-- 6. Refresh the buffer from disk — preserves fold state,
				--    rebuilds folds, and refreshes git extmarks.
				refresh_buffer(buf)

				vim.notify("filebuf: saved", vim.log.levels.INFO)
			end)

			-- If pcall caught an unexpected error (not a validation failure),
			-- surface it to the user.
			if not ok and not tostring(result):match("validation failed") then
				vim.notify("filebuf: save error – " .. tostring(result), vim.log.levels.ERROR)
			end
		end,
	})

	vim.bo[buf].modified = false

	if prof.enabled then
		M.profile_report()
	end
end

--- Setup entry point for lazy.nvim.  Accepts an optional configuration
--- table (merged into M.config) and registers user commands.
---
---@param opts? filebuf.Config
---
--- Usage (lazy.nvim):
---   {
---     "user/filebuf",
---     dir = "~/path/to/filebuf",
---     opts = { permanent_delete = false },
---     config = true,
---   }
--- Or (init.lua):
---   require("filebuf").setup({ permanent_delete = false })
function M.setup(opts)
	opts = opts or {}

	M.config = vim.tbl_deep_extend("force", M.config, opts)

	-- Ensure highlight groups exist so users can override them in their
	-- colorscheme before the first buffer is opened.
	define_git_highlights()
	define_filebuf_type_highlights()
	define_filebuf_highlights()

	-- Register the decoration provider once, globally.  Neovim calls the
	-- callbacks on every redraw, so extmarks are always up-to-date without
	-- manual refresh / clear cycles.
	vim.api.nvim_set_decoration_provider(deco_ns, {
		on_start = deco_on_start,
		on_win = deco_on_win,
	})

	vim.api.nvim_create_user_command("Filebuf", function()
		M.open()
	end, { desc = "Open filebuf listing buffer" })
	vim.api.nvim_create_user_command("FilebufToggleHidden", function()
		-- Find the filebuf buffer in the current tabpage, or fail gracefully
		local buf = vim.api.nvim_get_current_buf()
		if vim.b[buf] and vim.b[buf].filebuf_root then
			toggle_hidden(buf)
		else
			vim.notify("filebuf: not in a filebuf buffer", vim.log.levels.WARN)
		end
	end, { desc = "Toggle visibility of hidden (dot) files in filebuf" })
end

return M
