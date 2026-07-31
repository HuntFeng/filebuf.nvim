----------------------------------------------------------------------
-- find(1) execution + parsing into the snapshot row cache.
--
-- M.scan_into is the only producer of snapshot rows: it runs find(1) with
-- GNU find's %d/%y/%T@/%C@ printf format (or a BSD/macOS perl fallback),
-- parses the output into the row cache (filebuf.snapshot) and projects the
-- visible subset into buffer lines.  The rows outlive the render, so a later
-- toggle, re-sort or post-save refresh is a re-projection instead of another
-- find(1).
--
-- Also here: the async deep-scan job for render's shallow-first path
-- (M.run_find_async, GNU find only), and a same-filtering disk scan used as
-- the :w diff baseline (M.scan_disk_entries).
--
-- Ignored *directories* (from git ls-files) are passed to find -prune so
-- their subtrees are never even stat-ed -- a major win for node_modules and
-- similar.  Hidden entries are retained and filtered at projection time, so
-- toggling show_hidden is a re-projection; ignored subtrees are only
-- collected when the scan is allowed to, and snap.pruned records the gap so
-- a later "show hidden" knows it must rescan.
----------------------------------------------------------------------
local prof = require("filebuf.profiler")
local config = require("filebuf.config")
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

--- Build the GNU find(1) command table.
---@param root       string
---@param maxdepth   number
---@param prune_dirs table|nil
---@return table cmd
local function build_gnu_find_cmd(root, maxdepth, prune_dirs)
	local cmd = { "find", root }
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
		"%d\t%y\t%T@\t%C@\t%f\n",
	})
	return cmd
end

--- Run find(1) under `root`, optionally pruning ignored directories so
--- their subtrees are never stat-ed.
---@param root       string  absolute directory, no trailing slash
---@param maxdepth   number
---@param prune_dirs table|nil  relative directory paths to prune
---@return string|nil  stdout in depth\ttype\tname\n format
local function run_find(root, maxdepth, prune_dirs)
	if has_gnu_find() then
		local cmd = build_gnu_find_cmd(root, maxdepth, prune_dirs)
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
			[[chomp;$d=()=substr($_,%d)=~m|/|g;@s=lstat($_);next unless @s;$t=-d _?"d":(-l _?"l":"f");$i=rindex($_,"/");print "$d\t$t\t$s[9]\t$s[10]\t",substr($_,$i+1),"\n";]],
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

--- Run find(1) asynchronously via jobstart, collecting stdout with live
--- progress callbacks.
---
--- Only supports GNU find.  Returns nil for non-GNU systems; the caller
--- should fall back to a synchronous full-depth scan.
---
---@param root        string
---@param maxdepth    number
---@param prune_dirs  table|nil
---@param on_progress fun(count: number)|nil  called via vim.schedule
---@param on_done     fun(output: string|nil)  called via vim.schedule
---@return number|nil job_id
function M.run_find_async(root, maxdepth, prune_dirs, on_progress, on_done)
	if not has_gnu_find() then
		return nil
	end

	local cmd = build_gnu_find_cmd(root, maxdepth, prune_dirs)
	local chunks = {}
	local tail = "" -- leftover partial line from the previous chunk
	local count = 0
	local last_report = 0
	local REPORT_EVERY = 5000

	return vim.fn.jobstart(cmd, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			if not data or #data == 0 then
				return
			end
			-- Prepend the leftover partial line from the previous chunk.
			data[1] = tail .. data[1]
			-- All elements except the last are complete lines.
			for i = 1, #data - 1 do
				local line = data[i]
				if line ~= "" then
					chunks[#chunks + 1] = line
					count = count + 1
				end
			end
			-- The last element may be incomplete — save it.
			tail = data[#data] or ""
			if on_progress and count - last_report >= REPORT_EVERY then
				last_report = count
				vim.schedule(function()
					on_progress(count)
				end)
			end
		end,
		on_exit = function(_, exit_code)
			-- Flush the leftover tail (complete line, or empty if the
			-- output ended with \n).
			if tail ~= "" then
				chunks[#chunks + 1] = tail
				count = count + 1
				tail = ""
			end
			local output = table.concat(chunks, "\n")
			vim.schedule(function()
				if exit_code ~= 0 and #output == 0 then
					on_done(nil)
				else
					on_done(output)
				end
			end)
		end,
	})
end

----------------------------------------------------------------------
-- Common transform: find output -> visible entries
----------------------------------------------------------------------

--- Stream through find output, applying hidden/ignored filtering, calling
--- `on_entry` for each visible entry.
---@param output      string  raw find stdout
---@param root        string  absolute root
---@param show_hidden boolean
---@param ignore_set  table|nil  gitignored paths -> true
---@param on_entry    fun(name, path, ftype, indent, is_dir, mtime, ctime)
local function stream_entries(output, root, show_hidden, ignore_set, on_entry)
	local stack = {} -- { depth, path }
	local skip_below = nil

	for depth_str, ftype, mtime_str, ctime_str, name in
		output:gmatch("([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\n]*)\n")
	do
		local depth = tonumber(depth_str)
		if not depth then
			goto continue
		end
		local mtime = math.floor((tonumber(mtime_str) or 0) * 1000)
		local ctime = math.floor((tonumber(ctime_str) or 0) * 1000)
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

		local indent = depth - 1 -- depth 1 = indent 0
		on_entry(name, path, ftype, indent, is_dir, mtime, ctime)

		::continue::
	end
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
	prof.start("render.tree.scan.scan_into")
	opts = opts or {}
	local maxdepth = opts.maxdepth or config.max_depth or 20
	local show_hidden = opts.show_hidden
	if show_hidden == nil then
		show_hidden = config.show_hidden
	end

	-- Build gitignore set (1 system call, cached per root).
	prof.start("render.tree.scan.scan_into.ignore_set")
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

	prof.start("render.tree.scan.scan_into.find")
	root = root:gsub("(.)/+$", "%1")
	local output = run_find(root, maxdepth, prune_dirs)
	prof.stop()
	if not output then
		prof.stop()
		return nil
	end

	prof.start("render.tree.scan.scan_into.build")
	snap.root = root
	snapshot.build(snap, output, ignore_set, prune_dirs ~= nil and #prune_dirs > 0)
	prof.stop()

	prof.start("render.tree.scan.scan_into.project")
	snapshot.project(snap, config.sort_method, show_hidden)
	prof.stop()

	prof.start("render.tree.scan.scan_into.lines")
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
function M.scan_disk_entries(root, opts)
	prof.start("scan.scan_disk_entries")
	opts = opts or {}
	local maxdepth = opts.maxdepth or config.max_depth or 20
	local show_hidden = config.show_hidden

	prof.start("scan.scan_disk_entries.ignore_set")
	local ignore_set, ignored_dirs
	ignore_set, ignored_dirs = require("filebuf.git").build_ignore_set(root)
	prof.stop()

	local prune_dirs = (not show_hidden) and ignored_dirs or nil

	root = root:gsub("(.)/+$", "%1")
	prof.start("scan.scan_disk_entries.find")
	local output = run_find(root, maxdepth, prune_dirs)
	prof.stop()
	if not output then
		prof.stop()
		return nil
	end

	prof.start("scan.scan_disk_entries.stream")
	local entries = {}
	local n = 0
	stream_entries(output, root, show_hidden, ignore_set, function(name, path, ftype, indent, _, mtime, ctime)
		n = n + 1
		entries[n] = {
			name = name,
			path = path,
			type = ftype == "d" and "dir" or (ftype == "l" and "link" or "file"),
			indent = indent,
			mtime = mtime,
			ctime = ctime,
		}
	end)
	prof.stop()

	prof.stop()
	return entries
end

return M
