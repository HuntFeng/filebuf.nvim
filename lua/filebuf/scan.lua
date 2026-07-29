----------------------------------------------------------------------
-- Tree scanner -- streams find(1) output directly into buffer lines.
--
-- No in-memory tree, no grouping, no flattening.  The buffer IS the data
-- store.  find's %d (depth) maps directly to indent, %y maps to the
-- "/" / "@" suffix, and %f is the visible text.
--
-- The one thing find(1) cannot give us is order: its output is directory
-- order, so siblings get reordered once (filebuf.sort) before the lines
-- are built.
--
-- Hidden and gitignored subtrees are filtered inline via a skip-depth
-- marker.  Additionally, ignored *directories* (from git ls-files) are
-- passed to find -prune so their subtrees are never even stat-ed --
-- a major win for node_modules and similar.
----------------------------------------------------------------------
local prof = require("filebuf.profiler")
local config = require("filebuf.config")
local line_mod = require("filebuf.line")
local sort = require("filebuf.sort")
local snapshot = require("filebuf.snapshot")

local M = {}

----------------------------------------------------------------------
-- find(1) execution
----------------------------------------------------------------------

--- Cached check for GNU find (Linux).
local _gnu_find_cache = nil
local function has_gnu_find()
	if _gnu_find_cache ~= nil then
		return _gnu_find_cache
	end
	local ok, result = pcall(vim.fn.system, { "find", "--version" })
	_gnu_find_cache = ok and type(result) == "string" and result:match("GNU") ~= nil
	return _gnu_find_cache
end

--- Run find(1) under `root`, optionally pruning ignored directories so
--- their subtrees are never stat-ed.
---@param root       string  absolute directory, no trailing slash
---@param maxdepth   number
---@param prune_dirs table|nil  relative directory paths to prune
---@return string|nil  stdout in depth\ttype\tname\n format
local function run_find(root, maxdepth, prune_dirs)
	if has_gnu_find() then
		local cmd = { "find", root }
		-- Insert prune expressions:  \( -path X -prune \) -o ...
		if prune_dirs and #prune_dirs > 0 then
			for _, dir in ipairs(prune_dirs) do
				local escaped = dir:gsub("([%*%?%[%]])", "\\%1")
				cmd[#cmd + 1] = "("
				cmd[#cmd + 1] = "-path"
				cmd[#cmd + 1] = root .. "/" .. escaped
				cmd[#cmd + 1] = "-prune"
				cmd[#cmd + 1] = ")"
				cmd[#cmd + 1] = "-o"
			end
		end
		vim.list_extend(cmd, {
			"-maxdepth",
			tostring(maxdepth),
			"-mindepth",
			"1",
			"-printf",
			"%d\t%y\t%f\n",
		})
		local output = vim.fn.system(cmd)
		if vim.v.shell_error ~= 0 and #output == 0 then
			return nil
		end
		return output
	elseif vim.fn.executable("perl") == 1 then
		-- macOS / BSD: inject prune args into the find portion.
		local prune_args = ""
		if prune_dirs and #prune_dirs > 0 then
			local parts = {}
			for _, dir in ipairs(prune_dirs) do
				local escaped = dir:gsub("([%*%?%[%]])", "\\%1")
				parts[#parts + 1] = "-path " .. vim.fn.shellescape(root .. "/" .. escaped) .. " -prune -o"
			end
			prune_args = table.concat(parts, " ") .. " "
		end
		local esc_root = vim.fn.shellescape(root)
		local root_len = #root
		local perl_script = string.format(
			[[chomp;$d=()=substr($_,%d)=~m|/|g;@s=lstat($_);next unless @s;$t=-d _?"d":(-l _?"l":"f");$i=rindex($_,"/");print "$d\t$t\t",substr($_,$i+1),"\n";]],
			root_len
		)
		local esc_perl = vim.fn.shellescape(perl_script)
		local cmd = string.format(
			"find %s %s-maxdepth %d -mindepth 1 -print0 2>/dev/null | perl -0ne %s",
			esc_root,
			prune_args,
			maxdepth,
			esc_perl
		)
		local output = vim.fn.system(cmd)
		if vim.v.shell_error ~= 0 and #output == 0 then
			return nil
		end
		return output
	end
	return nil
end

----------------------------------------------------------------------
-- Common transform: find output -> visible entries
----------------------------------------------------------------------

--- Stream through find output, applying hidden/ignored filtering, calling
--- `on_entry` for each visible entry.
---@param output      string  raw find stdout
---@param root        string  absolute root
---@param maxdepth    number  depth cap
---@param show_hidden boolean
---@param ignore_set  table|nil  gitignored paths -> true
---@param on_entry    fun(name, path, ftype, indent, is_dir)
---@return table  truncated_dirs  dir paths at maxdepth -> true
local function stream_entries(output, root, maxdepth, show_hidden, ignore_set, on_entry)
	local truncated_dirs = {}
	local stack = {} -- { depth, path }
	local skip_below = nil

	for depth_str, ftype, name in output:gmatch("([^\t]*)\t([^\t]*)\t([^\n]*)\n") do
		local depth = tonumber(depth_str)
		if not depth then
			goto continue
		end
		local is_dir = ftype == "d"

		-- Pop stack to the true parent.
		while #stack > 0 and stack[#stack].depth >= depth do
			table.remove(stack)
		end

		-- Clear skip when depth climbs back above the skip threshold.
		if skip_below and depth <= skip_below then
			skip_below = nil
		end

		-- Compute absolute path.
		local parent_path = #stack > 0 and stack[#stack].path or root
		local path = parent_path == "/" and ("/" .. name) or (parent_path .. "/" .. name)

		-- Always push dirs for child path computation (even hidden ones).
		if is_dir then
			stack[#stack + 1] = { depth = depth, path = path }
		end

		-- Skip if we are inside a hidden/ignored subtree.
		if skip_below then
			goto continue
		end

		local is_hidden = name:sub(1, 1) == "."
		local is_ignored = ignore_set and ignore_set[path]

		-- Filter hidden/ignored when not showing them.
		if not show_hidden and (is_hidden or is_ignored) then
			if is_dir then
				skip_below = depth
			end
			goto continue
		end

		-- Mark directories at maxdepth as truncated (expandable).
		if is_dir and depth >= maxdepth then
			truncated_dirs[path] = true
		end

		local indent = depth - 1 -- depth 1 = indent 0
		on_entry(name, path, ftype, indent, is_dir)

		::continue::
	end

	return truncated_dirs
end

----------------------------------------------------------------------
-- Core: find -> snapshot -> buffer lines
----------------------------------------------------------------------

--- Scan `root` into `snap` and return the buffer lines for it.
---
--- This is the only producer of snapshot rows.  Unlike find_to_lines below,
--- what it produces outlives the render: `snap` keeps every row found on
--- disk (not just the visible ones), so a later toggle, re-sort or
--- post-save refresh is a re-projection instead of another find(1).
---
---@param snap  table   from snapshot.new
---@param root  string  absolute root directory
---@param opts? table   { maxdepth?: number, show_hidden?: boolean, prune?: boolean }
---@return string[]|nil lines
function M.scan_into(snap, root, opts)
	prof.start("scan.scan_into")
	opts = opts or {}
	local maxdepth = opts.maxdepth or config.max_depth or 20
	local show_hidden = opts.show_hidden
	if show_hidden == nil then
		show_hidden = config.show_hidden
	end

	-- Build gitignore set (1 system call, cached per root).
		prof.start("scan.scan_into.ignore_set")
		ignore_set, ignored_dirs = require("filebuf.git").build_ignore_set(root)
		prof.stop()

	-- Pruning keeps a cold open fast, at the cost of the snapshot not holding
	-- the ignored subtrees -- recorded as snap.pruned so a later "show hidden"
	-- knows it has to rescan once to fill them in.
	local prune = opts.prune
	if prune == nil then
		prune = not show_hidden
	end
	local prune_dirs = prune and ignored_dirs or nil

	prof.start("scan.scan_into.find")
	root = root:gsub("(.)/+$", "%1")
	local output = run_find(root, maxdepth, prune_dirs)
	prof.stop()
	if not output then
		prof.stop()
		return nil
	end

	prof.start("scan.scan_into.build")
	snap.root = root
	snapshot.build(snap, output, maxdepth, ignore_set, prune_dirs ~= nil and #prune_dirs > 0)
	prof.stop()

	prof.start("scan.scan_into.project")
	snapshot.project(snap, config.sort_method, show_hidden)
	prof.stop()

	prof.start("scan.scan_into.lines")
	local lines = snapshot.lines(snap)
	prof.stop()

	prof.stop()
	return lines, ignore_set
end


----------------------------------------------------------------------
-- Disk scan for save diffing (same filtering as the buffer)
----------------------------------------------------------------------

--- Scan the tree under `root` with the SAME visibility filtering as the
--- current buffer render, so hidden/ignored entries are never mistaken
--- for deletions.
---@param root string   absolute root directory
---@param opts? table   { maxdepth?: number }
---@return table[]|nil entries  { name, path, type, indent }
---@return boolean     truncated
function M.scan_disk_entries(root, opts)
	prof.start("scan.scan_disk_entries")
	opts = opts or {}
	local maxdepth = opts.maxdepth or config.max_depth or 20
	local show_hidden = config.show_hidden

	local ignore_set, ignored_dirs
		ignore_set, ignored_dirs = require("filebuf.git").build_ignore_set(root)
	local prune_dirs = (not show_hidden) and ignored_dirs or nil

	root = root:gsub("(.)/+$", "%1")
	local output = run_find(root, maxdepth, prune_dirs)
	if not output then
		prof.stop()
		return nil, false
	end

	local entries = {}
	local n = 0
	stream_entries(output, root, maxdepth, show_hidden, ignore_set, function(name, path, ftype, indent)
		n = n + 1
		entries[n] = {
			name = name,
			path = path,
			type = ftype == "d" and "dir" or (ftype == "l" and "link" or "file"),
			indent = indent,
		}
	end)

	prof.stop()
	return entries, false
end

----------------------------------------------------------------------
-- Single-directory scan (for lazy expand)
----------------------------------------------------------------------

--- Scan the immediate children of a single directory.
---@param dir   string
---@param root? string  kept for API compatibility
---@return table[]  { name, path, type, lazy? }
function M.scan_dir_children(dir, root)
	local handle = vim.loop.fs_scandir(dir)
	if not handle then
		return {}
	end

	local children = {}
	local n = 0
	while true do
		local name, ftype = vim.loop.fs_scandir_next(handle)
		if not name then
			break
		end
		local is_dir = ftype == "directory"
		n = n + 1
		children[n] = {
			name = name,
			path = dir .. "/" .. name,
			type = is_dir and "dir" or (ftype == "link" and "link" or "file"),
			lazy = is_dir or nil,
		}
	end

	-- All children are siblings, so a plain sort is enough here.
	local cmp = sort.comparator(config.sort_method)
	if cmp then
		table.sort(children, cmp)
	end
	return children
end

return M
