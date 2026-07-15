----------------------------------------------------------------------
-- filebuf — edit the filesystem as an editable buffer.
--
-- The whole non-hidden tree is rendered into one buffer with indent-based
-- folding; edits are diffed against disk and applied on :w.  This file wires
-- the modules together and exposes the public API; the heavy lifting lives in:
--   scan / buffer / diff / apply / git / folds / decoration / highlights
----------------------------------------------------------------------
local config = require("filebuf.config")
local prof = require("filebuf.profiler")
local line_mod = require("filebuf.line")
local scan = require("filebuf.scan")
local buffer = require("filebuf.buffer")
local diff = require("filebuf.diff")
local apply = require("filebuf.apply")
local git = require("filebuf.git")
local folds = require("filebuf.folds")
local highlights = require("filebuf.highlights")
local decoration = require("filebuf.decoration")

local M = {}

--- Public, user-mutable configuration (see filebuf.config).
M.config = config

--- Enable/disable the profiler; report to :messages.
function M.profile(enable)
	prof.set_enabled(enable)
end
function M.profile_report()
	return prof.report()
end

----------------------------------------------------------------------
-- Buffer rendering
----------------------------------------------------------------------

--- Rebuild the buffer from a display-entry list (1:1 with buffer lines).
--- Rebuilds folds, restores previously-open directories, persists fold
--- state, and refreshes cached git status.
---@param buf number
---@param entries table[]  display entries (already filtered for visibility)
---@param open_dirs table|nil  set of dir paths to keep open (nil = all closed)
local function rebuild_buffer_display(buf, entries, open_dirs)
	local dir = vim.b[buf].filebuf_root
	if not dir then
		return
	end

	-- Entries are 1:1 with lines; stamp lnum so folds/extmarks skip re-parsing.
	local lines = {}
	for i, entry in ipairs(entries) do
		entry.lnum = i
		lines[i] = line_mod.format_line(entry)
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	vim.b[buf].filebuf_display_entries = entries

	-- Rebuild all folds closed, then re-open the ones that were open before.
	vim.cmd("silent! normal! zE")
	folds.create_folds(buf, entries)
	for _, e in ipairs(entries) do
		if e.type == "dir" and open_dirs and open_dirs[e.path] then
			vim.cmd(string.format("silent! %dfoldopen", e.lnum))
		end
	end
	-- Persist after folds are rebuilt so newly-revealed dirs default to closed.
	folds.save_fold_state(buf, dir, entries)

	-- Cache git status for the decoration provider's next redraw.
	vim.b[buf].filebuf_git_status = git.get_status_map(dir)

	vim.bo[buf].modified = false

	if prof.enabled then
		prof.report()
	end
end

--- Snapshot which directories are currently open (fold not closed).
---@param entries table[]
---@return table  set of open dir paths
local function open_dirs_of(entries)
	local open = {}
	for _, e in ipairs(entries) do
		if e.type == "dir" and vim.fn.foldclosed(e.lnum) == -1 then
			open[e.path] = true
		end
	end
	return open
end

--- Re-read the tree from disk and refresh the buffer, preserving fold state.
---@param buf number
local function refresh_buffer(buf)
	local dir = vim.b[buf].filebuf_root
	if not dir then
		return
	end

	folds.save_fold_state(buf, dir)
	local open_dirs = open_dirs_of(vim.b[buf].filebuf_display_entries or {})

	local all_entries = scan.scan_tree(dir)
	vim.b[buf].filebuf_all_entries = all_entries
	vim.b[buf].filebuf_has_hidden = config.show_hidden

	rebuild_buffer_display(buf, scan.filter_visible(all_entries), open_dirs)
end

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------

--- Toggle show_hidden and refresh, preserving the cursor entry and fold state.
--- Refuses when there are unsaved changes.  The heavy -H hidden scan runs at
--- most once (cached via filebuf_has_hidden); later toggles re-filter memory.
---@param buf number
local function toggle_hidden(buf)
	if vim.bo[buf].modified then
		vim.notify("filebuf: save or discard changes before toggling hidden files", vim.log.levels.WARN)
		return
	end

	local dir = vim.b[buf].filebuf_root
	local pre_entries = vim.b[buf].filebuf_display_entries or {}
	local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
	local cursor_path = pre_entries[cursor_lnum] and pre_entries[cursor_lnum].path

	folds.save_fold_state(buf, dir, pre_entries)
	local open_dirs = open_dirs_of(pre_entries)

	config.show_hidden = not config.show_hidden

	-- filter_visible(full_set) yields the right view for either state, so we
	-- only need a fresh scan when revealing hidden entries not yet cached.
	local all_entries = vim.b[buf].filebuf_all_entries
	if config.show_hidden and not vim.b[buf].filebuf_has_hidden then
		all_entries = scan.scan_tree(dir)
		vim.b[buf].filebuf_all_entries = all_entries
		vim.b[buf].filebuf_has_hidden = true
	end
	all_entries = all_entries or scan.scan_tree(dir)
	rebuild_buffer_display(buf, scan.filter_visible(all_entries), open_dirs)

	-- Restore the cursor to the same entry (accounts for shifted line numbers).
	if cursor_path then
		for _, e in ipairs(vim.b[buf].filebuf_display_entries or {}) do
			if e.path == cursor_path then
				vim.api.nvim_win_set_cursor(0, { e.lnum, 0 })
				break
			end
		end
	end

	vim.notify("filebuf: hidden files " .. (config.show_hidden and "shown" or "hidden"), vim.log.levels.INFO)
end

--- Handle <CR>: toggle a directory fold, or open a file / follow a symlink.
---@param buf number
local function handle_enter(buf)
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local entries = vim.b[buf].filebuf_display_entries
	local entry = entries and entries[lnum]
	if not entry then
		return
	end

	if entry.type == "dir" then
		vim.api.nvim_win_set_cursor(0, { lnum, 0 })
		vim.cmd(vim.fn.foldclosedend(lnum) ~= -1 and "normal! zo" or "normal! zc")
		folds.save_fold_state(buf, vim.b[buf].filebuf_root)
	else
		local target = vim.loop.fs_realpath(entry.path) or entry.path
		if entry.type == "link" and vim.fn.isdirectory(target) == 1 then
			M.open(target) -- symlink → directory: open a new filebuf
		elseif vim.fn.filereadable(target) == 1 then
			vim.cmd("edit " .. vim.fn.fnameescape(target))
		else
			vim.notify("Cannot read: " .. entry.path, vim.log.levels.WARN)
		end
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

--- Open the filebuf browser rooted at `dir` (default: cwd).  The full tree is
--- loaded with subdirectories folded closed; <CR> toggles a fold or opens a
--- file.  Edits apply to disk only on :w; type mismatches block the save.
---@param dir string|nil
function M.open(dir)
	dir = (dir or vim.fn.getcwd()):gsub("/$", "") -- normalize trailing slash

	-- Capture the file being edited so we can auto-focus it once the tree exists.
	local current_file = vim.api.nvim_buf_get_name(0)

	local buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_name(buf, "filebuf://" .. dir) -- so :w triggers BufWriteCmd
	vim.b[buf].filebuf_root = dir
	vim.bo[buf].filetype = "filebuf"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].buftype = "acwrite"

	vim.keymap.set("n", "<CR>", function()
		handle_enter(buf)
	end, { buffer = buf, desc = "Open file / toggle directory fold" })
	vim.keymap.set("n", "q", function()
		folds.save_fold_state(buf, dir)
		vim.api.nvim_buf_delete(buf, { force = true })
	end, { buffer = buf, desc = "Close filebuf" })
	vim.keymap.set("n", "H", function()
		toggle_hidden(buf)
	end, { buffer = buf, desc = "Toggle hidden files" })

	-- Populate with the full tree; cache the unfiltered list so toggle_hidden
	-- can re-filter from memory instead of re-walking the filesystem.
	local all_entries = scan.scan_tree(dir)
	vim.b[buf].filebuf_all_entries = all_entries
	vim.b[buf].filebuf_has_hidden = config.show_hidden

	local display_entries = scan.filter_visible(all_entries)
	local lines = {}
	for i, e in ipairs(display_entries) do
		e.lnum = i
		lines[i] = line_mod.format_line(e)
	end
	if #lines > 0 then
		vim.api.nvim_buf_set_lines(buf, 0, 0, false, lines)
	end

	-- Manual folding: each directory + descendants form a fold, closed initially.
	vim.api.nvim_set_current_buf(buf)
	vim.wo.foldmethod = "manual"
	vim.wo.foldenable = true
	vim.wo.foldcolumn = "auto:9"
	vim.wo.foldtext = "v:lua.FilebufFoldText()"
	-- Override Folded's background (FilebufFoldLine fully replaces it — see
	-- highlights.lua for why a plain link to Directory leaks the background).
	vim.wo.winhighlight = "Folded:FilebufFoldLine"
	vim.wo.fillchars = (vim.wo.fillchars or "") .. "foldopen:▼,foldclose:▶,fold: "

	folds.create_folds(buf, display_entries)

	-- Restore saved fold state, or close everything on first open.
	if folds.closed[dir] then
		-- create_folds already closed every dir; open only the ones the user
		-- had expanded, so newly-revealed dirs default to closed.
		for _, e in ipairs(display_entries) do
			if e.type == "dir" and not folds.closed[dir][e.path] then
				vim.cmd(string.format("silent! %dfoldopen", e.lnum))
			end
		end
	else
		vim.cmd("silent! %foldclose!")
	end

	-- Auto-focus the file that was being edited before :Filebuf.
	if config.auto_focus_current_file and current_file ~= "" and vim.startswith(current_file, dir .. "/") then
		local target = vim.fn.resolve(current_file)
		local target_lnum, target_indent
		for _, e in ipairs(display_entries) do
			if vim.fn.resolve(e.path) == target then
				target_lnum, target_indent = e.lnum, e.indent
				break
			end
		end
		if target_lnum then
			-- Open the closest ancestor dir at each depth above the target.
			local ancestors = {}
			for _, e in ipairs(display_entries) do
				if e.type == "dir" and e.lnum < target_lnum and e.indent < target_indent then
					ancestors[e.indent] = e.lnum
				end
			end
			local sorted = {}
			for _, lnum in pairs(ancestors) do
				sorted[#sorted + 1] = lnum
			end
			table.sort(sorted) -- outermost (lowest indent) first
			for _, lnum in ipairs(sorted) do
				pcall(vim.cmd, string.format("%dfoldopen", lnum))
			end
			vim.api.nvim_win_set_cursor(0, { target_lnum, 0 })
			vim.cmd("normal! zz")
		end
	end

	vim.b[buf].filebuf_display_entries = display_entries
	vim.b[buf].filebuf_git_status = git.get_status_map(dir)

	-- :w → parse, diff against disk, validate, apply, refresh.
	local group = vim.api.nvim_create_augroup("filebuf_edit_" .. buf, { clear = true })
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = group,
		buffer = buf,
		callback = function()
			local ok, result = pcall(function()
				local buf_entries = buffer.parse_buffer(buf)
				-- Use the cached list as the disk baseline (avoids a re-scan);
				-- filter to visible so hidden files aren't seen as "deleted".
				local all_disk = vim.b[buf].filebuf_all_entries or scan.scan_tree(dir)
				local ops = diff.compute_diff(buf_entries, scan.filter_visible(all_disk))

				if #ops.errors > 0 then
					apply.report_errors(buf, ops.errors)
					error("filebuf: validation failed")
				end
				vim.diagnostic.reset(nil, buf)

				apply.apply_ops(ops)
				refresh_buffer(buf)
				vim.notify("filebuf: saved", vim.log.levels.INFO)
			end)
			if not ok and not tostring(result):match("validation failed") then
				vim.notify("filebuf: save error – " .. tostring(result), vim.log.levels.ERROR)
			end
		end,
	})

	vim.bo[buf].modified = false

	if prof.enabled then
		prof.report()
	end
end

--- Setup entry point.  Merges `opts` into config and registers commands.
---@param opts? filebuf.Config
function M.setup(opts)
	opts = opts or {}
	local merged = vim.tbl_deep_extend("force", config, opts)
	for k, v in pairs(merged) do
		config[k] = v -- mutate in place so all modules see the update
	end

	highlights.define()

	-- Register the decoration provider once; it refreshes extmarks on redraw.
	vim.api.nvim_set_decoration_provider(decoration.ns, {
		on_start = decoration.on_start,
		on_win = decoration.on_win,
	})

	vim.api.nvim_create_user_command("Filebuf", function()
		M.open()
	end, { desc = "Open filebuf listing buffer" })
	vim.api.nvim_create_user_command("FilebufToggleHidden", function()
		local buf = vim.api.nvim_get_current_buf()
		if vim.b[buf] and vim.b[buf].filebuf_root then
			toggle_hidden(buf)
		else
			vim.notify("filebuf: not in a filebuf buffer", vim.log.levels.WARN)
		end
	end, { desc = "Toggle visibility of hidden (dot) files in filebuf" })
end

return M
