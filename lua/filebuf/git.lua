----------------------------------------------------------------------
-- Git status indicators.  A single `git status --porcelain` per refresh
-- builds a path→status map the decoration provider consults per line.
----------------------------------------------------------------------
local prof = require("filebuf.profiler")

local M = {}

--- Unquote a path from `git status --porcelain` output.  Git wraps paths
--- with special characters in double quotes with C-style escaping.
---@param path string
---@return string
local function unquote(path)
	if path:sub(1, 1) == '"' and path:sub(-1) == '"' then
		path = path:sub(2, -2)
		path = path:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub("\\r", "\r"):gsub('\\"', '"'):gsub("\\\\", "\\")
	end
	return path
end

--- Run `git status --porcelain` in `root` and return a map of path →
--- { index, worktree } status codes, or nil outside a git repo.
---@param root string
---@return table|nil
function M.get_status_map(root)
	prof.start("get_git_status_map")
	local cmd =
		string.format("git -C %s status --porcelain --ignored=matching --untracked-files=all", vim.fn.shellescape(root))
	local output = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		prof.stop()
		return nil
	end

	local status_map = {}
	for line in output:gmatch("[^\r\n]+") do
		local x, y = line:sub(1, 1), line:sub(2, 2)
		local filename = unquote(line:sub(4))
		-- Renames are "R  old -> new"; keep the new name (each side may be quoted).
		if x == "R" then
			local arrow = filename:find(" -> ")
			if arrow then
				filename = unquote(filename:sub(arrow + 4))
			end
		end
		status_map[root .. "/" .. filename] = { index = x, worktree = y }
	end

	prof.stop()
	return status_map
end

-- porcelain code → { display char, highlight group }.  Worktree status is
-- preferred over index status (it reflects the current on-disk state).
local CODE_DISPLAY = {
	["?"] = { "U", "FilebufGitUntracked" },
	A = { "A", "FilebufGitAdded" },
	M = { "M", "FilebufGitModified" },
	D = { "D", "FilebufGitDeleted" },
	R = { "R", "FilebufGitRenamed" },
	U = { "C", "FilebufGitConflict" },
}

--- Look up the git status for a single entry.  Only entries that appear
--- verbatim in git-status output get a status; directory name colouring is
--- always left to the Directory highlight group.
---@param entry table
---@param status_map table|nil
---@return string|nil char
---@return string|nil hl_group
function M.entry_status(entry, status_map)
	local s = status_map and status_map[entry.path]
	if not s then
		return nil
	end
	local code = s.worktree ~= " " and s.worktree or (s.index ~= " " and s.index or nil)
	local d = code and CODE_DISPLAY[code]
	if d then
		return d[1], d[2]
	end
	return nil
end

return M
