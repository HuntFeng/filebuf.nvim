----------------------------------------------------------------------
-- Shared test utilities for filebuf.nvim integration tests.
----------------------------------------------------------------------

local M = {}

--- Create a temporary directory with a unique name under /tmp.
---@return string  absolute path to the temp directory
function M.create_temp_dir()
	local dir = "/tmp/filebuf_test_" .. math.floor(vim.loop.hrtime() / 1e6)
	vim.fn.mkdir(dir, "p")
	return dir
end

--- Recursively remove a directory and all its contents.
---@param dir string
function M.cleanup_dir(dir)
	vim.fn.delete(dir, "rf")
end

--- Populate a directory with files and subdirectories.
--- `structure` is a table mapping relative paths to either
--- a string (file content) or a table (subdirectory).
---
--- Example:
---   populate_dir("/tmp/foo", {
---     ["file.txt"] = "hello",
---     ["subdir"] = {},
---     ["subdir/nested.txt"] = "world",
---   })
---@param dir        string  root directory to populate
---@param structure  table   map of relative-path → content-string | table
function M.populate_dir(dir, structure)
	-- Collect keys and sort by depth so parents are created before children.
	local keys = vim.tbl_keys(structure)
	table.sort(keys, function(a, b)
		local da = select(2, a:gsub("/", "/"))
		local db = select(2, b:gsub("/", "/"))
		if da ~= db then
			return da < db
		end
		return a < b
	end)

	for _, rel_path in ipairs(keys) do
		local full_path = dir .. "/" .. rel_path
		local content = structure[rel_path]
		if type(content) == "table" then
			vim.fn.mkdir(full_path, "p")
		else
			local parent = vim.fn.fnamemodify(full_path, ":h")
			vim.fn.mkdir(parent, "p")
			local fd = vim.loop.fs_open(full_path, "w", 420) -- 0644
			if fd then
				vim.loop.fs_write(fd, content)
				vim.loop.fs_close(fd)
			end
		end
	end
end

--- Open filebuf on `dir` and return the buffer number.
--- Closes any previous filebuf buffer first to ensure a clean state.
---@param dir string
---@return number  buffer number
function M.open_filebuf(dir)
	-- Ensure no stale Filebuf buffer exists.
	local existing = vim.fn.bufnr("Filebuf")
	if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
		pcall(vim.api.nvim_buf_delete, existing, { force = true })
	end
	-- Wipe any remaining buffers that might have filebuf_root set.
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.b[bufnr] and vim.b[bufnr].filebuf_root then
			pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
		end
	end

	require("filebuf").open(dir)
	return vim.api.nvim_get_current_buf()
end

--- Wait for async git status to populate on a filebuf buffer.
--- After open/save, git status is fetched asynchronously via jobstart;
--- this polls vim.b[bufnr].filebuf_git_status until it's non-nil or
--- the timeout expires.
---@param bufnr  number   the filebuf buffer
---@param timeout_ms number  max wait time in ms (default 2000)
---@return table|nil  the git status map, or nil on timeout
function M.wait_for_git_status(bufnr, timeout_ms)
	timeout_ms = timeout_ms or 2000
	vim.wait(timeout_ms, function()
		return vim.b[bufnr].filebuf_git_status ~= nil
	end)
	return vim.b[bufnr].filebuf_git_status
end

--- Trigger save on the filebuf buffer (simulates :w).
--- Wraps in pcall because validation errors cause :w to throw in headless mode
--- (the BufWriteCmd handler's vim.notify escapes as a Vim(append) error).
---@param buf number
function M.save_buffer(buf)
	pcall(function()
		vim.api.nvim_buf_call(buf, function()
			vim.cmd("write")
		end)
	end)
end

--- Get all buffer lines as a table.
---@param buf number
---@return string[]
function M.get_buffer_lines(buf)
	return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Check whether a filesystem path exists and return its stat.
---@param path string
---@return table|nil  fs_stat result, or nil if not found
function M.fs_stat(path)
	return vim.loop.fs_stat(path)
end

--- Get the type of a filesystem entry ("file", "directory", "link", or nil).
---@param path string
---@return string|nil
function M.fs_type(path)
	local stat = vim.loop.fs_stat(path)
	if not stat then
		return nil
	end
	return stat.type
end

--- Get diagnostics for a buffer in the filebuf-diag namespace.
---@param buf number
---@return table[]  list of diagnostics { lnum, col, severity, message, ... }
function M.get_diagnostics(buf)
	local ns = vim.api.nvim_create_namespace("filebuf-diag")
	return vim.diagnostic.get(buf, { namespace = ns })
end

--- Clear the filebuf buffer and any related state.
---@param buf number
function M.close_filebuf(buf)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
	-- Clear persisted fold state.
	local actions = require("filebuf.actions")
	actions.closed = {}
end

--- Read the content of a file on disk.
---@param path string
---@return string|nil  file content or nil if unreadable
function M.read_file(path)
	local fd = vim.loop.fs_open(path, "r", 420)
	if not fd then
		return nil
	end
	local stat = vim.loop.fs_fstat(fd)
	local data = vim.loop.fs_read(fd, stat.size)
	vim.loop.fs_close(fd)
	return data
end

--- Run a shell command in `cwd` and return stdout as a string.
---@param cmd    string   shell command
---@param cwd    string   working directory
---@return string  stdout
function M.shell(cmd, cwd)
	local full = cwd and ("cd " .. vim.fn.shellescape(cwd) .. " && " .. cmd) or cmd
	local output = vim.fn.system(full)
	return output
end

--- Initialize a git repository in `dir` and configure a dummy user.
--- Returns true on success.
---@param dir string
---@return boolean
function M.git_init(dir)
	M.shell("git init", dir)
	M.shell("git config user.email 'test@filebuf.test'", dir)
	M.shell("git config user.name 'Filebuf Test'", dir)
	return vim.fn.isdirectory(dir .. "/.git") == 1
end

--- Stage (git add) a file relative to the repo root.
---@param dir     string  repo root
---@param relpath string  file path relative to dir
function M.git_add(dir, relpath)
	M.shell("git add " .. vim.fn.shellescape(relpath), dir)
end

--- Commit all staged changes in the repo.
---@param dir     string  repo root
---@param message string  commit message
function M.git_commit(dir, message)
	M.shell("git commit -m " .. vim.fn.shellescape(message or "test commit"), dir)
end

return M
