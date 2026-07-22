----------------------------------------------------------------------
-- Diff engine — compares parsed buffer entries against on-disk state and
-- produces the operations that reconcile disk with the buffer.
----------------------------------------------------------------------
local prof = require("filebuf.profiler")

local M = {}

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
				-- Type mismatch, e.g. a stray or missing trailing "/".
				local detail = be.type == "dir" and " (extra trailing '/')" or " (missing trailing '/')"
				errors[#errors + 1] = {
					lnum = be.lnum,
					message = string.format(
						"'%s' is a %s on disk but shown as %s in buffer%s",
						be.name,
						de.type,
						be.type,
						detail
					),
				}
			end
			unchanged[#unchanged + 1] = be
			consumed[de.path] = true
		else
			buf_unmatched[#buf_unmatched + 1] = be
		end
	end

	-- Phase 2: name-based rename matching.
	local disk_by_name = {}
	for _, de in ipairs(disk_entries) do
		if not consumed[de.path] then
			local list = disk_by_name[de.name]
			if not list then
				list = {}
				disk_by_name[de.name] = list
			end
			list[#list + 1] = de
		end
	end

	local renamed_disk = {} -- disk paths consumed by renames
	for _, be in ipairs(buf_unmatched) do
		local candidates = disk_by_name[be.name]
		local best
		if candidates then
			-- Prefer a same-parent match to avoid false positives across dirs.
			local be_parent = vim.fn.fnamemodify(be.path, ":h")
			for _, de in ipairs(candidates) do
				if not renamed_disk[de.path] then
					if vim.fn.fnamemodify(de.path, ":h") == be_parent then
						best = de
						break
					end
					best = best or de -- fallback: first unmatched same-name entry
				end
			end
		end

		if best then
			if (best.type == "dir") ~= (be.type == "dir") then
				errors[#errors + 1] = {
					lnum = be.lnum,
					message = string.format(
						"'%s' rename changes type: %s on disk -> %s in buffer",
						be.name,
						best.type,
						be.type
					),
				}
			end
			renamed[#renamed + 1] = { old = best, new = be }
			renamed_disk[best.path] = true
		else
			created[#created + 1] = be
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

return M
