----------------------------------------------------------------------
-- Git status indicators.  A single `git status --porcelain` per refresh
-- builds a path→status map the decoration provider consults per line.
----------------------------------------------------------------------
local prof = require("filebuf.profiler")

local M = {}


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
--- For directories, also computes an aggregated status from all descendants
--- so that closed folders still show what happened inside them.
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

	-- Aggregate git status up to parent directories so that closed
	-- folders still show what happened inside them.
	local dir_map = {} -- dir_path -> { [display_char] = hl_group }
	local root_len = #root
	for path, s in pairs(status_map) do
		local code = s.worktree ~= " " and s.worktree or (s.index ~= " " and s.index or nil)
		local d = code and CODE_DISPLAY[code]
		if d then
			local char, hl = d[1], d[2]
			local parent = vim.fn.fnamemodify(path, ":h")
			while #parent >= root_len do
				if not dir_map[parent] then
					dir_map[parent] = {}
				end
				dir_map[parent][char] = hl
				parent = vim.fn.fnamemodify(parent, ":h")
			end
		end
	end

	for dir_path, char_map in pairs(dir_map) do
		if not status_map[dir_path] then -- don't overwrite direct entries (e.g. submodules)
			local aggregated = {}
			local chars = vim.tbl_keys(char_map)
			table.sort(chars)
			for _, ch in ipairs(chars) do
				aggregated[#aggregated + 1] = { char = ch, hl = char_map[ch] }
			end
			status_map[dir_path] = { aggregated = aggregated }
		end
	end

	prof.stop()
	return status_map
end

--- Look up the git status for a single entry.  Only entries that appear
--- verbatim in git-status output get a status (files and submodules).
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

--- Look up the aggregated git status for a directory entry (computed
--- from all descendants in get_status_map).  Returns a table of
--- { char, hl } pairs, sorted by char, or nil.
---@param entry table
---@param status_map table|nil
---@return table|nil  { { char = string, hl = string }, ... }
function M.dir_status(entry, status_map)
	local s = status_map and status_map[entry.path]
	if not s or not s.aggregated then
		return nil
	end
	return s.aggregated
end

return M
