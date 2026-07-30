----------------------------------------------------------------------
-- Sync engine — compares parsed buffer entries against on-disk state
-- and applies the resulting operations to the filesystem.
----------------------------------------------------------------------
local prof = require("filebuf.profiler")
local config = require("filebuf.config")

local M = {}

--- Dedicated diagnostic namespace so error signs don't collide with other
--- plugins and won't throw "namespace: expected number, got nil" on older
--- Neovim versions that reject a nil namespace.
M.diag_ns = vim.api.nvim_create_namespace("filebuf-diag")

--- Parent directory of a path.  vim.fn.fnamemodify(p, ":h") does the same thing
--- but crosses into Vimscript, which shows up when the diff calls it once per
--- entry on a large tree.
---@param path string
---@return string
local function parent_of(path)
	return path:match("^(.*)/") or path
end

--- Depth of a path, measured by "/" count (for create/delete ordering).
local function depth(path)
	return select(2, path:gsub("/", "/"))
end

--- Compare the buffer's desired state with the filesystem.  Rename detection
--- is name-based: an unmatched buffer entry pairs with an unmatched disk entry
--- of the same name, preferring the same parent directory.
---@param buf_entries table[]   parsed buffer entries
---@param disk_entries table[]  scanned disk entries
---@return table  { unchanged, renamed, created, deleted, errors }
function M.compute_diff(buf_entries, disk_entries)
	prof.start("compute_diff")

	local disk_by_path = {}
	for _, de in ipairs(disk_entries) do
		disk_by_path[de.path] = de
	end

	local unchanged, renamed, created, deleted, errors = {}, {}, {}, {}, {}
	local consumed = {} -- disk paths already matched

	-- Phase 1: exact-path match.
	local buf_unmatched = {}
	for _, be in ipairs(buf_entries) do
		local de = disk_by_path[be.path]
		if de then
			if (de.type == "dir") ~= (be.type == "dir") then
				-- Type mismatch: user made a file into a folder or vice versa.
				-- Give a clear message with line number and reassurance.
				errors[#errors + 1] = {
					lnum = be.lnum,
					message = string.format(
						"Line %d: '%s' is a %s on disk, but you changed it to a %s. "
							.. "A %s cannot become a %s — nothing was saved.",
						be.lnum,
						be.name,
						de.type,
						be.type,
						de.type,
						be.type
					),
				}
			end
			unchanged[#unchanged + 1] = be
			consumed[de.path] = true
		else
			buf_unmatched[#buf_unmatched + 1] = be
		end
	end

	-- Phase 2: name-based rename matching (same name, different parent).
	--
	-- Each name's candidates carry a forward-only cursor, so a candidate is
	-- examined at most once across the whole phase.  Rescanning the candidate
	-- list per unmatched entry made this O(unmatched x candidates): renaming a
	-- loaded directory in a repo full of same-named files (index.ts, mod.rs,
	-- __init__.py) took 3.4s at 17.6k descendants and grew quadratically.
	--
	-- There is deliberately no same-parent preference here: same parent plus
	-- same name means the same path, which Phase 1 already consumed.
	local renamed_disk = {} -- disk paths consumed by renames
	local buf_unmatched2 = {} -- entries still unmatched after name-based matching

	local disk_by_name = {}
	if #buf_unmatched > 0 then
		for _, de in ipairs(disk_entries) do
			if not consumed[de.path] then
				local bucket = disk_by_name[de.name]
				if not bucket then
					bucket = { at = 1 }
					disk_by_name[de.name] = bucket
				end
				bucket[#bucket + 1] = de
			end
		end
	end

	--- Next candidate in `bucket` that no rename has claimed yet.
	local function take(bucket)
		if not bucket then
			return nil
		end
		local at = bucket.at
		while at <= #bucket do
			local de = bucket[at]
			if not renamed_disk[de.path] then
				bucket.at = at
				return de
			end
			at = at + 1
		end
		bucket.at = at
		return nil
	end

	for _, be in ipairs(buf_unmatched) do
		local best = take(disk_by_name[be.name])

		if best then
			if (best.type == "dir") ~= (be.type == "dir") then
				errors[#errors + 1] = {
					lnum = be.lnum,
					message = string.format(
						"Line %d: Renaming '%s' would change a %s (on disk) into a %s. "
							.. "Type changes are not allowed — nothing was saved.",
						be.lnum,
						be.name,
						best.type,
						be.type
					),
				}
			end
			renamed[#renamed + 1] = { old = best, new = be }
			renamed_disk[best.path] = true
		else
			buf_unmatched2[#buf_unmatched2 + 1] = be
		end
	end

	-- Phase 2.5: same-parent matching — detects in-place renames where the
	-- name changed but the parent directory stayed the same.  Without this,
	-- in-place renames would be treated as delete (old path) + create (new
	-- empty file), losing the original content.
	--
	-- Directories participate only when neither side has children loaded into
	-- the buffer.  An in-place rename of a dir whose children *are* loaded is
	-- left to delete+create: Phase 2 already paired each child individually
	-- (their paths reference the new parent name), so the children move out
	-- before the old dir is removed and nothing is lost.  But a dir whose
	-- children were never loaded — the normal case now that every directory is
	-- lazy — has no such child renames, so delete+create would destroy the
	-- entire unloaded subtree.  Those must become a real fs_rename.
	if #buf_unmatched2 > 0 then
		local disk_by_parent = {}
		for _, de in ipairs(disk_entries) do
			if not consumed[de.path] and not renamed_disk[de.path] then
				local parent = parent_of(de.path)
				local list = disk_by_parent[parent]
				if not list then
					list = {}
					disk_by_parent[parent] = list
				end
				list[#list + 1] = de
			end
		end

		--- Set of dir paths that have at least one descendant in `entries`.
		local function paths_with_children(entries)
			local parents = {}
			for _, e in ipairs(entries) do
				parents[parent_of(e.path)] = true
			end
			return parents
		end
		local buf_parents = paths_with_children(buf_entries)
		local disk_parents = paths_with_children(disk_entries)

		for _, be in ipairs(buf_unmatched2) do
			local want_dir = be.type == "dir"
			-- A dir with loaded children is handled by delete+create (see above).
			if want_dir and buf_parents[be.path] then
				created[#created + 1] = be
				goto continue
			end
			local be_parent = parent_of(be.path)
			local candidates = disk_by_parent[be_parent]
			local best
			if candidates then
				-- Take the first available disk entry of the matching kind in
				-- the same parent.  Dirs pair only with childless dirs; files
				-- and links never pair with a dir.
				for i, de in ipairs(candidates) do
					local de_is_dir = de.type == "dir"
					if
						not renamed_disk[de.path]
						and de_is_dir == want_dir
						and not (want_dir and disk_parents[de.path])
					then
						best = de
						table.remove(candidates, i)
						break
					end
				end
			end
			if best then
				renamed[#renamed + 1] = { old = best, new = be }
				renamed_disk[best.path] = true
			else
				created[#created + 1] = be
			end
			::continue::
		end
	end

	-- Phase 3: remaining unmatched disk entries are deletes.
	for _, de in ipairs(disk_entries) do
		if not consumed[de.path] and not renamed_disk[de.path] then
			deleted[#deleted + 1] = de
		end
	end

	prof.stop()
	return { unchanged = unchanged, renamed = renamed, created = created, deleted = deleted, errors = errors }
end

--- Report validation errors as inline diagnostic signs at the offending lines
--- plus a summary notification.  Diagnostic calls are wrapped in pcall so a
--- Neovim version mismatch in the diagnostic API can never crash the save.
---@param buf number
---@param errors table[]  { lnum, message }
function M.report_errors(buf, errors)
	-- Clear previous diagnostics (safe-wrapped — nil ns can throw on older Neovim).
	pcall(vim.diagnostic.reset, M.diag_ns, buf)
	if #errors == 0 then
		return
	end
	local diags = {}
	for _, err in ipairs(errors) do
		diags[#diags + 1] = {
			lnum = (err.lnum or 1) - 1, -- 0-indexed
			col = 0,
			severity = vim.diagnostic.severity.ERROR,
			message = err.message,
			source = "filebuf",
		}
	end
	-- Place error signs at the offending lines (safe-wrapped).
	pcall(vim.diagnostic.set, M.diag_ns, buf, diags)
	vim.notify(
		string.format("filebuf: %d error(s) — nothing was saved; fix the marked lines and try again", #errors),
		vim.log.levels.ERROR
	)
end

--- Apply the computed operations to the filesystem, in order:
---   1. Renames (before deletes, so sources move out before parents vanish).
---   2. Deletes (deepest first, so children go before parents).
---   3. Creates (shallowest first, with mkdir -p semantics).
---@param ops table  result of compute_diff()
function M.apply_ops(ops)
	prof.start("sync.apply_ops")

	-- 1. Renames.
	prof.start("sync.apply_ops.renames")
	for _, r in ipairs(ops.renamed) do
		vim.fn.mkdir(vim.fn.fnamemodify(r.new.path, ":h"), "p")
		local ok, err = pcall(vim.loop.fs_rename, r.old.path, r.new.path)
		if not ok then
			vim.notify("filebuf: cannot rename – " .. (err or r.old.path), vim.log.levels.ERROR)
		end
	end
	prof.stop()

	-- 2. Deletes, deepest path first, so children go before their parents.
	-- Depth is the "/" count, not the string length: "/a/bbbbbbbb" is longer
	-- than "/a/b/c" but shallower, and sorting by length got that backwards.
	prof.start("sync.apply_ops.deletes")
	local to_delete = ops.deleted
	table.sort(to_delete, function(a, b)
		return depth(a.path) > depth(b.path)
	end)

	-- When permanent_delete is off, everything deleted this save goes into a
	-- single timestamped recovery folder.
	local trash_dir
	if not config.permanent_delete and #to_delete > 0 then
		trash_dir = string.format("/tmp/filebuf_trash/%s", os.date("%Y_%m_%d_%H_%M_%S"))
		vim.fn.mkdir(trash_dir, "p")
	end

	for _, de in ipairs(to_delete) do
		if trash_dir then
			local dest = trash_dir .. "/" .. de.name
			local n = 1
			while vim.loop.fs_stat(dest) do -- avoid collisions in the trash folder
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
	prof.stop()

	-- 3. Creates, parents before children (dirs before files at equal depth).
	prof.start("sync.apply_ops.creates")
	table.sort(ops.created, function(a, b)
		local da, db = depth(a.path), depth(b.path)
		if da ~= db then
			return da < db
		end
		return a.type == "dir" and b.type ~= "dir"
	end)
	for _, be in ipairs(ops.created) do
		if be.type == "dir" then
			local ok, err = pcall(vim.fn.mkdir, be.path, "p")
			if not ok then
				vim.notify("filebuf: cannot create dir – " .. (err or be.path), vim.log.levels.ERROR)
			end
		else
			vim.fn.mkdir(vim.fn.fnamemodify(be.path, ":h"), "p")
			local fd, err = vim.loop.fs_open(be.path, "w", 420) -- 0644
			if not fd then
				vim.notify("filebuf: cannot create file – " .. (err or be.path), vim.log.levels.ERROR)
			else
				vim.loop.fs_close(fd)
			end
		end
	end
	prof.stop()

	prof.stop()
end

return M
