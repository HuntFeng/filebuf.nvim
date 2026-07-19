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

--- Re-read the tree from disk and refresh the buffer, preserving fold state
--- and any previously-expanded lazy directories.
---@param buf number
local function refresh_buffer(buf)
	local dir = vim.b[buf].filebuf_root
	if not dir then
		return
	end

	folds.save_fold_state(buf, dir)
	local open_dirs = open_dirs_of(vim.b[buf].filebuf_display_entries or {})

	-- Capture which lazy dirs were expanded before the refresh.
	local previously_expanded = vim.b[buf].filebuf_lazy_expanded or {}
	vim.b[buf].filebuf_lazy_expanded = {}

	local all_entries, by_parent = scan.scan_tree(dir)
	vim.b[buf].filebuf_all_entries = all_entries
	vim.b[buf].filebuf_by_parent = by_parent

	-- Re-expand lazy dirs that were expanded before the refresh.
	-- Must operate on the all_entries list in a forward pass so that splices
	-- don't shift positions we haven't reached yet.
	local i = 1
	while i <= #all_entries do
		local entry = all_entries[i]
		if entry.lazy and previously_expanded[entry.path] then
			local children = scan.scan_dir_children(entry.path, by_parent)
			local parent_indent = entry.indent
			for _, child in ipairs(children) do
				child.indent = parent_indent + 1
			end
			-- Splice children into all_entries after entry.
			for j = #children, 1, -1 do
				table.insert(all_entries, i + 1, children[j])
			end
			entry.lazy = nil
			local exp_rb = vim.b[buf].filebuf_lazy_expanded or {}
			exp_rb[entry.path] = true
			vim.b[buf].filebuf_lazy_expanded = exp_rb
			vim.b[buf].filebuf_all_entries = all_entries
			i = i + #children
		end
		i = i + 1
	end

	rebuild_buffer_display(buf, scan.filter_visible(all_entries), open_dirs)
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
	local open_dirs = open_dirs_of(pre_entries)

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

--- Find the index of an entry in a list (reference equality).
---@param entries table[]
---@param target  table
---@return number|nil
local function find_entry_index(entries, target)
	for i, e in ipairs(entries) do
		if e == target then
			return i
		end
	end
	return nil
end

--- Expand a lazy directory: scan its immediate children, insert them into the
--- buffer and both entry caches, rebuild folds, and open the fold.
--- Idempotent — if the entry is no longer lazy (already expanded), this is a
--- no-op to prevent duplicate children.
---@param buf        number
---@param lazy_entry table  the lazy directory entry
local function expand_lazy_dir(buf, lazy_entry)
	-- Ensure the expanded-set table exists (may be nil if buffer state
	-- was lost), and mark this path expanded BEFORE doing any work so
	-- that a failure mid-way cannot lead to double-expansion.
	local expanded = vim.b[buf].filebuf_lazy_expanded
	if not expanded then
		expanded = {}
		vim.b[buf].filebuf_lazy_expanded = expanded
	end
	if not lazy_entry.lazy or expanded[lazy_entry.path] then
		return -- already expanded, nothing to do
	end
	expanded[lazy_entry.path] = true
	vim.b[buf].filebuf_lazy_expanded = expanded

	-- vim.b returns a snapshot, not a live reference — always re-read
	-- after writing back so we operate on the freshest copy.
	local display = vim.b[buf].filebuf_display_entries
	local all_entries = vim.b[buf].filebuf_all_entries
	local by_parent = vim.b[buf].filebuf_by_parent

	-- 1. Scan immediate children.
	local children = scan.scan_dir_children(lazy_entry.path, by_parent)

	-- 2. Set indent (parent indent + 1).
	local parent_indent = lazy_entry.indent
	for _, child in ipairs(children) do
		child.indent = parent_indent + 1
	end

	-- 3. Splice children into filebuf_all_entries (diff baseline).
	--    Use reference equality first; fall back to path match because
	--    display and all_entries may hold different objects after a
	--    re-scan (refresh_buffer creates brand-new entry tables).
	local all_pos = find_entry_index(all_entries, lazy_entry)
	if not all_pos then
		for i, e in ipairs(all_entries) do
			if e.path == lazy_entry.path then
				all_pos = i
				break
			end
		end
	end
	if all_pos then
		for i = #children, 1, -1 do
			table.insert(all_entries, all_pos + 1, children[i])
		end
		vim.b[buf].filebuf_all_entries = all_entries
	end

	-- Snapshot which dirs are open BEFORE we modify anything, since
	-- line insertion and zE both affect fold state.
	local open_dirs = open_dirs_of(display)
	open_dirs[lazy_entry.path] = true -- ensure expanded dir ends up open

	-- 4. Destroy existing folds BEFORE inserting lines.  If we insert first,
	-- Neovim may try to adjust manual fold ranges, which can corrupt state.
	vim.cmd("silent! normal! zE")

	-- 5. Insert only visible children into display entries + buffer text.
	local visible_children = scan.filter_visible(children)
	local child_lines = {}
	for i, child in ipairs(visible_children) do
		child_lines[i] = line_mod.format_line(child)
	end

	if #child_lines > 0 then
		local insert_lnum = lazy_entry.lnum -- insert after the parent line
		vim.api.nvim_buf_set_lines(buf, insert_lnum, insert_lnum, false, child_lines)

		for i = #visible_children, 1, -1 do
			table.insert(display, insert_lnum + 1, visible_children[i])
		end
	end

	-- 6. Re-stamp lnum on all display entries.
	for i = 1, #display do
		display[i].lnum = i
	end

	-- 7. Clear lazy flag on every reference to this entry (display and
	-- all_entries may hold different objects after a re-scan).
	lazy_entry.lazy = nil
	for _, e in ipairs(all_entries) do
		if e.path == lazy_entry.path then
			e.lazy = nil
		end
	end
	vim.b[buf].filebuf_display_entries = display
	vim.b[buf].filebuf_all_entries = all_entries


	-- 8. Rebuild folds and restore previously-open directories.
	folds.create_folds(buf, display)
	for _, e in ipairs(display) do
		if e.type == "dir" and open_dirs[e.path] then
			vim.cmd(string.format("silent! %dfoldopen", e.lnum))
		end
	end

  -- Mark the buffer modified: we inserted lines (expanding a lazy dir
  -- changes what's displayed), even though nothing on disk changed yet.
  vim.bo[buf].modified = false
end

--- Recursively expand a lazy directory and all nested lazy dirs within it.
---@param buf        number
---@param lazy_entry table
local function expand_lazy_dir_recursive(buf, lazy_entry)
	if not lazy_entry.lazy then
		return -- already expanded
	end
	expand_lazy_dir(buf, lazy_entry)
	-- Collect lazy child paths first (expansion shifts indices, so we
	-- can't safely iterate while expanding).
	local display = vim.b[buf].filebuf_display_entries
	local start = lazy_entry.lnum
	local finish = #display
	for i = start + 1, #display do
		if display[i].indent <= lazy_entry.indent then
			finish = i - 1
			break
		end
	end
	local lazy_paths = {}
	local expanded = vim.b[buf].filebuf_lazy_expanded or {}
	for i = start + 1, finish do
		if display[i].lazy and not expanded[display[i].path] then
			lazy_paths[#lazy_paths + 1] = display[i].path
		end
	end
	for _, path in ipairs(lazy_paths) do
		-- Re-read display each iteration: expand_lazy_dir (called
		-- recursively) writes back to vim.b, which returns snapshots.
		display = vim.b[buf].filebuf_display_entries
		expanded = vim.b[buf].filebuf_lazy_expanded or {}
		for _, e in ipairs(display) do
			if e.path == path and e.lazy and not expanded[e.path] then
				expand_lazy_dir_recursive(buf, e)
				break
			end
		end
	end
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
		-- Only expand if truly lazy AND not already expanded (double guard).
		if entry.lazy and not (vim.b[buf].filebuf_lazy_expanded or {})[entry.path] then
			expand_lazy_dir(buf, entry)
			return
		end
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
  -- If a filebuf for this directory already exists, switch to it and refresh.
  local existing_buf = vim.fn.bufnr("Filebuf")
  if existing_buf ~= -1 and vim.api.nvim_buf_is_valid(existing_buf) then
    vim.api.nvim_set_current_buf(existing_buf)
    refresh_buffer(existing_buf)
    return
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

	-- Native fold commands: expand lazy dirs before opening folds.
	vim.keymap.set("n", "zo", function()
		local lnum = vim.api.nvim_win_get_cursor(0)[1]
		local entries = vim.b[buf].filebuf_display_entries
		local entry = entries and entries[lnum]
		if entry and entry.lazy and not (vim.b[buf].filebuf_lazy_expanded or {})[entry.path] then
			expand_lazy_dir(buf, entry)
		else
			vim.cmd("normal! zo")
		end
	end, { buffer = buf, desc = "Open fold / expand lazy dir" })
	vim.keymap.set("n", "za", function()
		local lnum = vim.api.nvim_win_get_cursor(0)[1]
		local entries = vim.b[buf].filebuf_display_entries
		local entry = entries and entries[lnum]
		if entry and entry.lazy and not (vim.b[buf].filebuf_lazy_expanded or {})[entry.path] then
			expand_lazy_dir(buf, entry)

		elseif entry and entry.type == "dir" then
			vim.cmd("normal! za")
		end
	end, { buffer = buf, desc = "Toggle fold / expand lazy dir" })
	vim.keymap.set("n", "zO", function()
		local lnum = vim.api.nvim_win_get_cursor(0)[1]
		local entries = vim.b[buf].filebuf_display_entries
		local entry = entries and entries[lnum]
		if entry and entry.lazy and not (vim.b[buf].filebuf_lazy_expanded or {})[entry.path] then
			expand_lazy_dir_recursive(buf, entry)
		else
			vim.cmd("normal! zO")
		end
	end, { buffer = buf, desc = "Recursively open folds / expand lazy dir" })
	vim.keymap.set("n", "zR", function()
		local entries = vim.b[buf].filebuf_display_entries
		if entries then
			-- Collect lazy paths first; expanding mutates the list.
			local lazy_paths = {}
			for _, e in ipairs(entries) do
				if e.lazy and not (vim.b[buf].filebuf_lazy_expanded or {})[e.path] then
					lazy_paths[#lazy_paths + 1] = e.path
				end
			end
			for _, path in ipairs(lazy_paths) do
				for _, e in ipairs(vim.b[buf].filebuf_display_entries or {}) do
					if e.path == path and e.lazy and not (vim.b[buf].filebuf_lazy_expanded or {})[e.path] then
						expand_lazy_dir(buf, e)
						break
					end
				end
			end
		end
		vim.cmd("normal! zR")
	end, { buffer = buf, desc = "Open all folds / expand all lazy dirs" })

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
