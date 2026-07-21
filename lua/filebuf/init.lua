----------------------------------------------------------------------
-- filebuf — edit the filesystem as an editable buffer.
--
-- The whole non-hidden tree is rendered into one buffer with indent-based
-- folding; edits are diffed against disk and applied on :w.  This file wires
-- the modules together and exposes the public API; the heavy lifting lives in:
--   scan / buffer / diff / apply / git / folds / decoration / highlights
--   actions (public fold & lazy-expand API)
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
local actions = require("filebuf.actions")

local M = {}

--- Public, user-mutable configuration (see filebuf.config).
M.config = config

--- Public fold / lazy-expand / entry-open API.
--- Callable from user keymaps, autocommands, or scripts.
---@see filebuf.actions
M.actions = actions

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

	-- Rebuild all folds and restore previously-open directories.
	actions.rebuild_folds(buf, entries, open_dirs)

	-- Persist after folds are rebuilt so newly-revealed dirs default to closed.
	folds.save_fold_state(buf, dir, entries)

	-- Cache git status for the decoration provider's next redraw.
	vim.b[buf].filebuf_git_status = git.get_status_map(dir)

	vim.bo[buf].modified = false

	if prof.enabled then
		prof.report()
	end
end

--- Re-read the tree from disk and refresh the buffer, preserving fold state
--- and any previously-expanded lazy directories.
---@param buf number
local function refresh_buffer(buf)
	local dir = vim.b[buf].filebuf_root
	if not dir then
		return
	end

	folds.save_fold_state(buf, dir)
	local display_entries = vim.b[buf].filebuf_display_entries
	local open_dirs = {}
	if display_entries then
		for _, e in ipairs(display_entries) do
			if e.type == "dir" and vim.fn.foldclosed(e.lnum) == -1 then
				open_dirs[e.path] = true
			end
		end
	end

	-- Capture which lazy dirs were expanded before the refresh.
	local previously_expanded = vim.b[buf].filebuf_lazy_expanded or {}
	vim.b[buf].filebuf_lazy_expanded = {}

	local new_all_entries, by_parent = scan.scan_tree(dir)
	vim.b[buf].filebuf_all_entries = new_all_entries
	vim.b[buf].filebuf_by_parent = by_parent

	-- Re-expand lazy dirs that were expanded before the refresh.
	-- Must operate in a forward pass so splices don't shift positions
	-- we haven't reached yet.
	local i = 1
	while i <= #new_all_entries do
		local entry = new_all_entries[i]
		if entry.lazy and previously_expanded[entry.path] then
			local children = scan.scan_dir_children(entry.path, by_parent)
			local parent_indent = entry.indent
			for _, child in ipairs(children) do
				child.indent = parent_indent + 1
				if entry.is_hidden then
					child.is_hidden = true
				end
				if entry.is_ignored then
					child.is_ignored = true
				end
			end
			-- Splice children into all_entries after entry.
			for j = #children, 1, -1 do
				table.insert(new_all_entries, i + 1, children[j])
			end
			entry.lazy = nil
			local exp_rb = vim.b[buf].filebuf_lazy_expanded or {}
			exp_rb[entry.path] = true
			vim.b[buf].filebuf_lazy_expanded = exp_rb
			vim.b[buf].filebuf_all_entries = new_all_entries
			i = i + #children
		end
		i = i + 1
	end

	rebuild_buffer_display(buf, scan.filter_visible(new_all_entries), open_dirs)
end

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------

--- Toggle show_hidden and refresh, preserving the cursor entry and fold state.
--- Refuses when there are unsaved changes.  With hybrid mode, hidden entries
--- are already cached as lazy placeholders in filebuf_all_entries, so toggling
--- is just a re-filter — no heavy re-scan is ever needed.
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
	local open_dirs = {}
	for _, e in ipairs(pre_entries) do
		if e.type == "dir" and vim.fn.foldclosed(e.lnum) == -1 then
			open_dirs[e.path] = true
		end
	end

	config.show_hidden = not config.show_hidden

	-- Hidden entries are already in filebuf_all_entries (as lazy placeholders),
	-- so toggling is a pure re-filter.  Re-scan only if the cache is missing.
	local all_entries = vim.b[buf].filebuf_all_entries
	if not all_entries then
		local entries, by_parent = scan.scan_tree(dir)
		all_entries = entries
		vim.b[buf].filebuf_all_entries = all_entries
		vim.b[buf].filebuf_by_parent = by_parent
	end
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

--- Set up buffer-local keymaps from config.
---@param buf number
local function setup_keymaps(buf, dir)
	local km = config.keymaps

	-- fold_open
	if km.fold_open then
		vim.keymap.set("n", km.fold_open, function()
			local entry = actions.get_entry_at_cursor(buf)
			if entry then
				actions.fold_open(buf, entry)
			end
		end, { buffer = buf, desc = "filebuf: open fold" })
	end

	-- fold_close
	if km.fold_close then
		vim.keymap.set("n", km.fold_close, function()
			local entry = actions.get_entry_at_cursor(buf)
			if entry then
				actions.fold_close(buf, entry)
			end
		end, { buffer = buf, desc = "filebuf: close fold" })
	end

	-- fold_toggle
	if km.fold_toggle then
		vim.keymap.set("n", km.fold_toggle, function()
			local entry = actions.get_entry_at_cursor(buf)
			if entry then
				actions.fold_toggle(buf, entry)
			end
		end, { buffer = buf, desc = "filebuf: toggle fold" })
	end

	-- fold_open_recursive
	if km.fold_open_recursive then
		vim.keymap.set("n", km.fold_open_recursive, function()
			local entry = actions.get_entry_at_cursor(buf)
			if entry then
				actions.fold_open_recursive(buf, entry)
			end
		end, { buffer = buf, desc = "filebuf: recursively open folds" })
	end

	-- fold_open_all
	if km.fold_open_all then
		vim.keymap.set("n", km.fold_open_all, function()
			actions.fold_open_all(buf)
		end, { buffer = buf, desc = "filebuf: open all folds" })
	end

	-- fold_close_all
	if km.fold_close_all then
		vim.keymap.set("n", km.fold_close_all, function()
			actions.fold_close_all(buf)
		end, { buffer = buf, desc = "filebuf: close all folds" })
	end

	-- open_or_toggle
	if km.open_or_toggle then
		vim.keymap.set("n", km.open_or_toggle, function()
			local entry = actions.get_entry_at_cursor(buf)
			if entry then
				actions.open_or_toggle(buf, entry)
			end
		end, { buffer = buf, desc = "filebuf: open file / toggle dir" })
	end

	-- toggle_hidden
	if km.toggle_hidden then
		vim.keymap.set("n", km.toggle_hidden, function()
			toggle_hidden(buf)
		end, { buffer = buf, desc = "filebuf: toggle hidden files" })
	end

	-- close_filebuf
	if km.close_filebuf then
		vim.keymap.set("n", km.close_filebuf, function()
			folds.save_fold_state(buf, dir)
			vim.api.nvim_buf_delete(buf, { force = true })
		end, { buffer = buf, desc = "filebuf: close" })
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

	-- If a filebuf for this directory already exists and is a real filebuf
	-- (not a hollow session-restored shell), switch to it and refresh.
	local existing_buf = vim.fn.bufnr("Filebuf")
	if existing_buf ~= -1 and vim.api.nvim_buf_is_valid(existing_buf) then
		if vim.b[existing_buf].filebuf_root then
			vim.api.nvim_set_current_buf(existing_buf)
			refresh_buffer(existing_buf)
			return
		end
		-- Stale session-restored buffer: wipe so we create a fresh one below.
		pcall(vim.api.nvim_buf_delete, existing_buf, { force = true })
	end

	-- Capture the file being edited so we can auto-focus it once the tree exists.
	local current_file = vim.api.nvim_buf_get_name(0)

	local buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_name(buf, "Filebuf") -- so :w triggers BufWriteCmd
	vim.b[buf].filebuf_root = dir
	vim.bo[buf].filetype = "filebuf"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].buflisted = false

	-- Set up configurable keymaps.
	setup_keymaps(buf, dir)

	-- Populate with the full tree; cache the unfiltered list so toggle_hidden
	-- can re-filter from memory instead of re-walking the filesystem.
	local all_entries, by_parent = scan.scan_tree(dir)
	vim.b[buf].filebuf_all_entries = all_entries
	vim.b[buf].filebuf_by_parent = by_parent
	vim.b[buf].filebuf_lazy_expanded = {}

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
				local all_disk = vim.b[buf].filebuf_all_entries
				if not all_disk then
					all_disk = scan.scan_tree(dir)
				end
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
