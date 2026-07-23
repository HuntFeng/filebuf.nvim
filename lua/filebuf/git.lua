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

--- Parse `git status --porcelain` output into a path→status map.
--- Extracted so both the sync and async paths share the same logic.
---@param root   string  root directory (prepended to relative paths)
---@param output string  raw stdout from git status --porcelain
---@return table  status_map
function M.parse_status_output(root, output)
	local status_map = {}
	for line in output:gmatch("[^\r\n]+") do
		local x, y = line:sub(1, 1), line:sub(2, 2)
		local filename = unquote(line:sub(4))
		if x == "R" then
			local arrow = filename:find(" -> ")
			if arrow then
				filename = unquote(filename:sub(arrow + 4))
			end
		end
		status_map[root .. "/" .. filename] = { index = x, worktree = y }
	end

	local dir_map = {}
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
		if not status_map[dir_path] then
			local aggregated = {}
			local chars = vim.tbl_keys(char_map)
			table.sort(chars)
			for _, ch in ipairs(chars) do
				aggregated[#aggregated + 1] = { char = ch, hl = char_map[ch] }
			end
			status_map[dir_path] = { aggregated = aggregated }
		end
	end

	return status_map
end

--- Run `git status --porcelain` synchronously and return a path→status map.
--- Prefer get_status_map_async for interactive use so git doesn't block the UI.
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
	local status_map = M.parse_status_output(root, output)
	prof.stop()
	return status_map
end

--- Run `git status --porcelain` asynchronously via jobstart.  When complete,
--- the result is written into vim.b[bufnr].filebuf_git_status so the decoration
--- provider picks it up on the next redraw.  This keeps git's ~25 ms latency
--- off the critical path during open and save.
---@param root  string  root directory
---@param bufnr number  buffer to update with filebuf_git_status
function M.get_status_map_async(root, bufnr)
	local argv = { "git", "-C", root, "status", "--porcelain", "--ignored=matching", "--untracked-files=all" }
	vim.fn.jobstart(argv, {
		stdout_buffered = true,
		on_stdout = function(_, data)
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end
			local output = table.concat(data or {}, "\n")
			vim.b[bufnr].filebuf_git_status = M.parse_status_output(root, output)
		end,
		on_exit = function(_, exit_code)
			if exit_code ~= 0 and vim.api.nvim_buf_is_valid(bufnr) then
				vim.b[bufnr].filebuf_git_status = nil
			end
		end,
	})
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
