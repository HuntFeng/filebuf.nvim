----------------------------------------------------------------------
-- filebuf hijack — intercept directory opens so they use filebuf
-- instead of netrw.  Four mechanisms work together:
--
--   1. Disable netrw so its BufReadCmd / FileExplorer handlers don't
--      compete with ours.
--   2. BufAdd * catches every buffer added to the buffer list.  When the
--      buffer name is a directory we set buftype=nofile BEFORE Vim tries
--      to read it, which prevents the E17 "is a directory" error.  Then
--      we open filebuf in its place.  BufAdd fires earlier than BufReadPre
--      — before the buftype gate — so this actually works.
--   3. VimEnter catches nvim <dir> from the command line when the plugin
--      is loaded early enough (i.e. before VimEnter fires).
--   4. A late-loading guard at the end of setup() catches the case where
--      the plugin was loaded after VimEnter (lazy-loaded on :Filebuf etc.).
--      It checks whether the current buffer is a directory and handles it.
--   5. :Ex / :Explore / :Vexplore / etc. aliases reroute the built-in
--      explorer commands to filebuf.
--
-- Regular files are never affected: the BufAdd handler returns immediately
-- when the target is not a directory.
----------------------------------------------------------------------
local M = {}

--- Disable netrw's plugin so its autocmds never load.  We must do this
--- before the plugin/ directory is sourced; calling it from a Lua
--- require() during init.lua is early enough.
local function disable_netrw()
	vim.g.loaded_netrw = 1
	vim.g.loaded_netrwPlugin = 1
	vim.g.loaded_netrwSettings = 1
	vim.g.loaded_netrwFileHandlers = 1
end

--- Given a raw file name, return the absolute normalized path with
--- trailing slash stripped, or nil if the name is empty / unset.
---@param raw string
---@return string|nil
local function resolve_path(raw)
	if not raw or raw == "" then
		return nil
	end
	return vim.fn.fnamemodify(raw, ":p"):gsub("/$", "")
end

--- Check whether `path` is a directory, silently returning false on
--- missing / inaccessible paths.
---@param path string
---@return boolean
local function is_directory(path)
	return vim.fn.isdirectory(path) == 1
end

--- Replace the current directory buffer with a filebuf at `dir`.
--- `buf` may have already been deleted by another handler; we guard
--- against that with pcall.
---@param buf  number   the directory buffer to replace
---@param dir  string   absolute path to open in filebuf
local function replace_with_filebuf(buf, dir)
	vim.schedule(function()
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
		require("filebuf").open(dir)
	end)
end

--- BufAdd handler: when a buffer whose name is a directory is added to
--- the buffer list we set buftype=nofile before Vim tries to read it,
--- then open filebuf.  For non-directory buffers this returns immediately.
---@param args table  autocmd args (buf, file)
local function on_buf_add(args)
	local name = vim.api.nvim_buf_get_name(args.buf)
	if name == "" then
		return -- new scratch buffer, not a file
	end

	local full = resolve_path(name)
	if not full or not is_directory(full) then
		return -- regular file — let Vim handle it normally
	end

	-- Prevent Vim from ever trying to read the directory as a file.
	-- This must happen in BufAdd (not BufReadPre) because the buftype
	-- gate is checked before BufReadPre fires.
	vim.bo[args.buf].buftype = "nofile"

	replace_with_filebuf(args.buf, full)
end

--- VimEnter handler: nvim <directory> from the command line.
--- This catches the startup buffer when the plugin was loaded early
--- enough (i.e. before VimEnter fires).
local function on_vim_enter()
	local buf = vim.api.nvim_get_current_buf()
	local name = vim.api.nvim_buf_get_name(buf)
	if name == "" then
		return
	end

	local full = resolve_path(name)
	if not full or not is_directory(full) then
		return
	end

	replace_with_filebuf(buf, full)
end

--- Late-loading guard: if the plugin was loaded after VimEnter already
--- fired (e.g. lazy-loaded on :Filebuf), check whether the current buffer
--- is a directory and handle it now.
local function handle_late_load()
	if vim.v.vim_did_enter ~= 1 then
		return -- VimEnter hasn't fired yet; the autocmd will handle it
	end

	local buf = vim.api.nvim_get_current_buf()
	local name = vim.api.nvim_buf_get_name(buf)
	if name == "" then
		return
	end

	local full = resolve_path(name)
	if not full or not is_directory(full) then
		return
	end

	replace_with_filebuf(buf, full)
end

--- Create a user-command alias for a built-in netrw explorer command.
--- If the user has already defined the command we leave it alone.
---@param cmd string   command name (e.g. "Ex", "Explore")
local function alias_explore_command(cmd)
	-- Check whether a user command with this name already exists.
	local existing = vim.api.nvim_get_commands({})
	if existing[cmd] then
		return -- already defined, don't clobber
	end
	vim.api.nvim_create_user_command(cmd, function(opts)
		local dir
		if opts.args ~= "" then
			dir = vim.fn.fnamemodify(vim.fn.expand(opts.args), ":p"):gsub("/$", "")
		else
			dir = vim.fn.getcwd()
		end
		require("filebuf").open(dir)
	end, { nargs = "?", desc = "filebuf: explore directory" })
end

--- Set up all autocmds and command aliases.  Safe to call multiple
--- times; clears any previous filebuf hijack autocmds first.
function M.setup()
	disable_netrw()

	local group = vim.api.nvim_create_augroup("FilebufHijackNetrw", { clear = true })

	-- 1. Intercept every buffer-add: when it's a directory, set buftype=nofile
	--    before Vim tries to read it (prevents E17), then open filebuf.
	vim.api.nvim_create_autocmd("BufAdd", {
		group = group,
		pattern = "*",
		callback = on_buf_add,
	})

	-- 2. Intercept nvim <dir> on the command line (when plugin is loaded
	--    before VimEnter).
	vim.api.nvim_create_autocmd("VimEnter", {
		group = group,
		pattern = "*",
		callback = on_vim_enter,
	})

	-- 3. Handle the case where the plugin was lazy-loaded after VimEnter
	--    already fired (the autocmd above was never registered in time).
	handle_late_load()

	-- 4. Alias built-in exploration commands.
	for _, cmd in ipairs({ "Ex", "Explore", "Rexplore", "Vexplore", "Sexplore", "Texplore", "Hexplore" }) do
		alias_explore_command(cmd)
	end
end

return M
