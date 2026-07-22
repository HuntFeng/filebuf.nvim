----------------------------------------------------------------------
-- Operation applicator — executes diff results on the filesystem and
-- reports validation errors.
----------------------------------------------------------------------
local config = require("filebuf.config")

local M = {}

--- Report validation errors as inline diagnostics plus one notify summary.
---@param buf number
---@param errors table[]  { lnum, message }
function M.report_errors(buf, errors)
	vim.diagnostic.reset(nil, buf)
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
	vim.diagnostic.set(nil, buf, diags)
	vim.notify(string.format("filebuf: %d error(s) — fix and save again", #errors), vim.log.levels.ERROR)
end

--- Depth of a path, measured by "/" count (for create/delete ordering).
local function depth(path)
	return select(2, path:gsub("/", "/"))
end

--- Apply the computed operations to the filesystem, in order:
---   1. Renames (before deletes, so sources move out before parents vanish).
---   2. Deletes (deepest first, so children go before parents).
---   3. Creates (shallowest first, with mkdir -p semantics).
---@param ops table  result of compute_diff()
function M.apply_ops(ops)
	-- 1. Renames.
	for _, r in ipairs(ops.renamed) do
		vim.fn.mkdir(vim.fn.fnamemodify(r.new.path, ":h"), "p")
		local ok, err = pcall(vim.loop.fs_rename, r.old.path, r.new.path)
		if not ok then
			vim.notify("filebuf: cannot rename – " .. (err or r.old.path), vim.log.levels.ERROR)
		end
	end

	-- 2. Deletes, deepest path first.
	local to_delete = ops.deleted
	table.sort(to_delete, function(a, b)
		return #a.path > #b.path
	end)

	-- When permanent_delete is off, everything deleted this save goes into a
	-- single timestamped recovery folder.
	local trash_dir
	if not config.permanent_delete and #to_delete > 0 then
		trash_dir = string.format("/tmp/filebuf-trash/%s", os.date("%Y_%m_%d_%H_%M_%S"))
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

	-- 3. Creates, parents before children (dirs before files at equal depth).
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
end

return M
