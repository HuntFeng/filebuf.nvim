----------------------------------------------------------------------
-- filebuf — edit the filesystem as an editable buffer.
--
-- The whole non-hidden tree is rendered into one buffer with indent-based
-- folding; edits are diffed against disk and applied on :w.  This file wires
-- the modules together and exposes the public API; the heavy lifting lives in:
--   scan / buffer / sync / git / actions / decoration
--   actions (public fold & lazy-expand API)
----------------------------------------------------------------------
local config = require("filebuf.config")
local prof = require("filebuf.profiler")
local line_mod = require("filebuf.line")
local scan = require("filebuf.scan")
local buffer = require("filebuf.buffer")
local sync = require("filebuf.sync")
local git = require("filebuf.git")
local decoration = require("filebuf.decoration")
local actions = require("filebuf.actions")
local search = require("filebuf.search")
local find = require("filebuf.find")

local M = {}

--- Set winbar on every window that displays `buf`.
--- vim.wo.winbar is window-local; when multiple windows show the same
--- filebuf buffer, we must update each one so the mode line stays in sync.
---@param buf number
---@param text string
local function set_winbar(buf, text)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		vim.api.nvim_set_option_value("winbar", text, { win = win })
	end
end

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
	prof.start("rebuild_buffer_display")
	local dir = vim.b[buf].filebuf_root
	if not dir then
		prof.stop()
		return
	end

	-- Entries are 1:1 with lines; stamp lnum so folds/extmarks skip re-parsing.
	prof.start("rebuild.format_lines")
	local lines = {}
	for i, entry in ipairs(entries) do
		entry.lnum = i
		lines[i] = line_mod.format_line(entry)
	end
	prof.stop() -- rebuild.format_lines

	-- Stamp display entries AND set the rebuilding flag BEFORE touching
	-- buffer content.  This lets the decoration provider's on_win callback
	-- return the already-current entries directly instead of re-parsing
	-- the whole buffer on every redraw (saves ~9 parse_buffer calls / save).
	vim.b[buf].filebuf_display_entries = entries
	vim.b[buf].filebuf_rebuilding = true

	buffer.without_undo(buf, function()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	end)
	buffer.clear_undo(buf)

	-- Rebuild all folds and restore previously-open directories.
	actions.rebuild_folds(buf, entries, open_dirs)

	-- Persist after folds are rebuilt so newly-revealed dirs default to closed.
	actions.save_fold_state(buf, dir, entries)

	-- Kick off async git status so it doesn't block the critical path.
	-- Clear old status immediately; the async callback populates when ready.
	vim.b[buf].filebuf_git_status = nil
	git.get_status_map_async(dir, buf)

	vim.b[buf].filebuf_rebuilding = nil
	vim.bo[buf].modified = false

	if prof.enabled then
		prof.report()
	end
	prof.stop()
end

--- Re-read the tree from disk and refresh the buffer, preserving fold state
--- and any previously-expanded lazy directories.
---@param buf number
local function refresh_buffer(buf)
	prof.start("refresh_buffer")
	local dir = vim.b[buf].filebuf_root
	if not dir then
		prof.stop()
		return
	end

	-- save to restore cursor pos and everything later
	local win_info = vim.fn.winsaveview()

	local display_entries = vim.b[buf].filebuf_display_entries

	actions.save_fold_state(buf, dir)
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

	-- Search match lnums no longer mean anything after a rebuild.
	search.clear(buf)

	scan.clear_ignore_cache()
	local new_all_entries = scan.scan_tree(dir)
	vim.b[buf].filebuf_all_entries = new_all_entries

	-- Re-expand lazy dirs that were expanded before the refresh.  A forward
	-- pass is required both so splices don't shift positions we haven't reached
	-- yet, and so a parent is spliced in before the loop reaches its children.
	prof.start("refresh.re_expand_lazy")
	local i = 1
	while i <= #new_all_entries do
		local entry = new_all_entries[i]
		if entry.lazy and previously_expanded[entry.path] then
			local children = scan.scan_dir_children(entry.path, dir)
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
			-- Deliberately do NOT skip past the children: they were just
			-- scanned as lazy placeholders themselves, and any of them that was
			-- also expanded before the refresh has to be re-expanded in turn.
			-- entry.lazy is cleared above, so index i can't be revisited.
		end
		i = i + 1
	end
	prof.stop() -- refresh.re_expand_lazy

	rebuild_buffer_display(buf, scan.filter_visible(new_all_entries), open_dirs)

	vim.fn.winrestview(win_info)
	prof.stop()
end

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------

local SORT_METHODS = { "type", "name", "modified", "created" }

--- Toggle show_hidden and refresh, preserving the cursor entry and fold state.
--- When there are unsaved changes, edits are merged into filebuf_all_entries
--- before toggling so they survive the buffer rebuild (like a VCS rebase).
--- Hidden entries are already cached as lazy placeholders in filebuf_all_entries,
--- so toggling is a re-filter — no heavy re-scan is ever needed.
---@param buf number
local function toggle_hidden(buf)
	prof.start("toggle_hidden")
	local dir = vim.b[buf].filebuf_root
	local pre_entries = vim.b[buf].filebuf_display_entries or {}
	local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
	local cursor_path = pre_entries[cursor_lnum] and pre_entries[cursor_lnum].path

	-- If the buffer has unsaved edits, merge them into filebuf_all_entries
	-- before toggling so they survive the buffer rebuild.  The edits are
	-- diffed against the last-rendered display baseline, then applied to
	-- the in-memory entry list — just like a VCS rebase.
	local has_edits = vim.bo[buf].modified
	if has_edits then
		local buf_entries = buffer.parse_buffer(buf)
		local baseline = pre_entries
		local ops = sync.compute_diff(buf_entries, baseline)

		if #ops.errors > 0 then
			sync.report_errors(buf, ops.errors)
			vim.notify("filebuf: fix errors before toggling hidden files", vim.log.levels.WARN)
			prof.stop()
			return
		end

		-- Clear stale diagnostics from a previously failed save.
		pcall(vim.diagnostic.reset, sync.diag_ns, buf)

		-- Ensure the cache is loaded before mutating it.
		local all_entries = vim.b[buf].filebuf_all_entries
		if not all_entries then
			all_entries = scan.scan_tree(dir)
		end
		-- Snapshot the clean disk state before merging edits, so the
		-- :w handler can diff against the true filesystem baseline
		-- rather than the edit-contaminated cache.  Only snapshot on
		-- the first toggle — subsequent toggles reuse it.
		if not vim.b[buf].filebuf_disk_baseline then
			local snapshot = {}
			for _, e in ipairs(all_entries) do
				snapshot[#snapshot + 1] = vim.deepcopy(e)
			end
			vim.b[buf].filebuf_disk_baseline = snapshot
		end

		sync.apply_ops_to_entries(all_entries, ops)
		vim.b[buf].filebuf_all_entries = all_entries
	end

	actions.save_fold_state(buf, dir, pre_entries)
	local open_dirs = {}
	for _, e in ipairs(pre_entries) do
		if e.type == "dir" and vim.fn.foldclosed(e.lnum) == -1 then
			open_dirs[e.path] = true
		end
	end

	config.show_hidden = not config.show_hidden

	-- Every loaded directory's hidden/ignored entries are already in
	-- filebuf_all_entries, so toggling is a pure re-filter — never a re-scan.
	-- Re-scan only if the cache is missing entirely.
	local all_entries = vim.b[buf].filebuf_all_entries
	if not all_entries then
		all_entries = scan.scan_tree(dir)
		vim.b[buf].filebuf_all_entries = all_entries
	end
	rebuild_buffer_display(buf, scan.filter_visible(all_entries), open_dirs)

	-- Preserve the modified flag when edits were merged in: the buffer
	-- content still represents unsaved changes to the filesystem.
	if has_edits then
		vim.bo[buf].modified = true
	end

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
	prof.stop()
end

--- Set up buffer-local keymaps from config.
---@param buf number
local function setup_keymaps(buf, dir)
	local km = config.keymaps

	-- Uniform entry-action keymaps: resolve cursor entry, call an actions function.
	local ENTRY_KEYMAPS = {
		fold_open = { actions.fold_open, "filebuf: open fold" },
		fold_close = { actions.fold_close, "filebuf: close fold" },
		fold_toggle = { actions.fold_toggle, "filebuf: toggle fold" },
		fold_open_recursive = { actions.fold_open_recursive, "filebuf: recursively open folds" },
		open_file = { actions.open_entry, "filebuf: open file" },
		open_or_toggle = { actions.open_or_toggle, "filebuf: open file / toggle dir" },
		preview = { actions.preview_entry, "filebuf: preview file" },
	}
	for name, def in pairs(ENTRY_KEYMAPS) do
		local key = km[name]
		if key then
			local fn = def[1]
			local desc = def[2]
			vim.keymap.set("n", key, function()
				local entry = actions.get_entry_at_cursor(buf)
				if entry then
					fn(buf, entry)
				end
			end, { buffer = buf, desc = desc })
		end
	end

	-- Buffer-wide action keymaps (no entry resolution needed).
	local BUF_KEYMAPS = {
		fold_open_all = { actions.fold_open_all, "filebuf: open all folds" },
		fold_close_all = { actions.fold_close_all, "filebuf: close all folds" },
	}
	for name, def in pairs(BUF_KEYMAPS) do
		local key = km[name]
		if key then
			vim.keymap.set("n", key, function()
				def[1](buf)
			end, { buffer = buf, desc = def[2] })
		end
	end

	-- toggle_hidden (custom — toggles config.show_hidden)
	if km.toggle_hidden then
		vim.keymap.set("n", km.toggle_hidden, function()
			toggle_hidden(buf)
		end, { buffer = buf, desc = "filebuf: toggle hidden files" })
	end

	-- close_filebuf (custom — persists folds before deleting buffer)
	if km.close_filebuf then
		vim.keymap.set("n", km.close_filebuf, function()
			actions.save_fold_state(buf, dir)
			vim.api.nvim_buf_delete(buf, { force = true })
		end, { buffer = buf, desc = "filebuf: close" })
	end

	-- find_mode (custom — enter async find mode)
	if km.find_mode then
		vim.keymap.set("n", km.find_mode, function()
			find.enter(buf)
		end, { buffer = buf, desc = "filebuf: find mode" })
	end
end

--- Build a confirmation message from diff ops and ask the user to confirm.
--- Returns true if the user confirms, false if they cancel.
---@param ops table  result of sync.compute_diff()
---@param root string  filebuf root directory (for relative paths)
---@return boolean
local function confirm_save(ops, root)
	local lines = { "Apply the following changes to the filesystem?" }

	-- Format a path relative to the filebuf root.
	local function rel(p)
		return p:sub(#root + 2) -- strip root .. "/"
	end

	local MAX_SHOWN = 20 -- cap per category to keep the dialog readable

	-- Creates
	if #ops.created > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = string.format("Create (%d):", #ops.created)
		for i = 1, math.min(#ops.created, MAX_SHOWN) do
			local e = ops.created[i]
			lines[#lines + 1] = "  + " .. rel(e.path) .. (e.type == "dir" and "/" or "")
		end
		if #ops.created > MAX_SHOWN then
			lines[#lines + 1] = string.format("  ... and %d more", #ops.created - MAX_SHOWN)
		end
	end

	-- Deletes
	if #ops.deleted > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = string.format("Delete (%d):", #ops.deleted)
		for i = 1, math.min(#ops.deleted, MAX_SHOWN) do
			local e = ops.deleted[i]
			lines[#lines + 1] = "  - " .. rel(e.path) .. (e.type == "dir" and "/" or "")
		end
		if #ops.deleted > MAX_SHOWN then
			lines[#lines + 1] = string.format("  ... and %d more", #ops.deleted - MAX_SHOWN)
		end
	end

	-- Renames
	if #ops.renamed > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = string.format("Rename (%d):", #ops.renamed)
		for i = 1, math.min(#ops.renamed, MAX_SHOWN) do
			local r = ops.renamed[i]
			lines[#lines + 1] = "  ~ " .. rel(r.old.path) .. " → " .. rel(r.new.path)
		end
		if #ops.renamed > MAX_SHOWN then
			lines[#lines + 1] = string.format("  ... and %d more", #ops.renamed - MAX_SHOWN)
		end
	end

	local message = table.concat(lines, "\n")
	local choice = vim.fn.confirm(message, "&Yes\n&No", 1, "Question")
	return choice == 1
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

--- Open the filebuf browser rooted at `dir` (default: cwd).  Only the root's
--- immediate children are loaded; every directory is a lazy placeholder whose
--- children appear when it is expanded (<CR> / zo) or when a search reveals a
--- path through it.  Edits apply to disk only on :w; type mismatches block the
--- save.
---@param dir string|nil
function M.open(dir)
	prof.start("open_filebuf")
	dir = (dir or vim.fn.getcwd()):gsub("/$", "") -- normalize trailing slash

	-- If a filebuf for this directory already exists and is a real filebuf
	-- (not a hollow session-restored shell), switch to it and refresh.
	local existing_buf = vim.fn.bufnr("Filebuf")
	if existing_buf ~= -1 and vim.api.nvim_buf_is_valid(existing_buf) then
		if vim.b[existing_buf].filebuf_root then
			vim.b[existing_buf].filebuf_root = dir
			vim.api.nvim_set_current_buf(existing_buf)
			refresh_buffer(existing_buf)
			prof.stop()
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

	-- Load only the root's immediate children — every directory below is a lazy
	-- placeholder.  The unfiltered list is cached so toggle_hidden is a pure
	-- re-filter rather than a re-scan.
	scan.clear_ignore_cache()
	local all_entries = scan.scan_tree(dir)
	vim.b[buf].filebuf_all_entries = all_entries
	vim.b[buf].filebuf_lazy_expanded = {}
	vim.b[buf].filebuf_mode = "normal"

	-- Manual folding: each directory + descendants form a fold, closed
	-- initially.  Window options go first so rebuild_buffer_display's fold
	-- work below sees them.  Unexpanded lazy dirs have no children on screen
	-- and therefore no fold — the trailing "/" is their only cue.
	vim.api.nvim_set_current_buf(buf)
	vim.wo.foldmethod = "manual"
	vim.wo.foldenable = true
	vim.wo.foldcolumn = "auto:9"
	vim.wo.foldtext = "v:lua.FilebufFoldText()"
	vim.wo.winhighlight = "Folded:FilebufFoldLine"
	vim.opt_local.fillchars:append({
		foldopen = "▼",
		foldclose = "▶",
		fold = " ",
	})
	set_winbar(buf, "Normal")

	-- Restore saved fold state: everything starts closed, so only the dirs the
	-- user had left open are reopened (newly-revealed dirs default to closed).
	local open_dirs
	if actions.closed[dir] then
		open_dirs = {}
		for _, e in ipairs(all_entries) do
			if e.type == "dir" and not actions.closed[dir][e.path] then
				open_dirs[e.path] = true
			end
		end
	end
	rebuild_buffer_display(buf, scan.filter_visible(all_entries), open_dirs)

	-- Auto-focus the file that was being edited before :Filebuf.  Its ancestors
	-- aren't loaded yet, so reveal_path expands the chain down to it (and opens
	-- the folds on the way) before we place the cursor.
	if config.auto_focus_current_file and current_file ~= "" and vim.startswith(current_file, dir .. "/") then
		local target = actions.reveal_path(buf, vim.fn.resolve(current_file)) or actions.reveal_path(buf, current_file)
		if target then
			vim.api.nvim_win_set_cursor(0, { target.lnum, 0 })
			vim.cmd("normal! zz")
		end
	end

	-- :w → parse, diff against disk, validate, apply, refresh.
	local group = vim.api.nvim_create_augroup("filebuf_edit_" .. buf, { clear = true })
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = group,
		buffer = buf,
		callback = function()
			prof.start("save_filebuf")
			local ok, result = pcall(function()
				local buf_entries = buffer.parse_buffer(buf)
				-- In find mode, scope the diff to the query tree only (the shown entries).
				-- Otherwise, prefer the clean disk snapshot (from toggle_hidden) over
				-- the live cache, which may contain merged edits.
				local disk_baseline
				if vim.b[buf].filebuf_mode == "find" then
					disk_baseline = vim.b[buf].filebuf_query_entries or {}
				else
					disk_baseline = vim.b[buf].filebuf_disk_baseline
					if not disk_baseline then
						disk_baseline = vim.b[buf].filebuf_all_entries
					end
					if not disk_baseline then
						disk_baseline = scan.scan_tree(dir)
					end
					disk_baseline = scan.filter_visible(disk_baseline)
				end
				local ops = sync.compute_diff(buf_entries, disk_baseline)

				if #ops.errors > 0 then
					sync.report_errors(buf, ops.errors)
					error("filebuf: validation failed")
				end
				-- Clear any stale diagnostics on successful validation (safe-wrapped).
				pcall(vim.diagnostic.reset, sync.diag_ns, buf)

				-- Save confirmation (when enabled and there are actual changes).
				local has_changes = #ops.renamed > 0 or #ops.created > 0 or #ops.deleted > 0
				if config.save_confirmation and has_changes then
					if not confirm_save(ops, dir) then
						vim.notify("filebuf: save cancelled", vim.log.levels.INFO)
						prof.stop()
						return
					end
				end

				prof.start("save.apply_ops")
				sync.apply_ops(ops)
				prof.stop() -- save.apply_ops

				-- Clear the disk snapshot now that edits have been
				-- persisted; the next toggle will start fresh.
				vim.b[buf].filebuf_disk_baseline = nil

				-- If we're in find mode, exit it (save implies commitment to the edits,
				-- and we show the full tree again). Update the mode banner.
				if vim.b[buf].filebuf_mode == "find" then
					find.exit(buf)
				end

				refresh_buffer(buf)
				-- Ensure the mode banner is visible after refresh.
				vim.b[buf].filebuf_mode = vim.b[buf].filebuf_mode or "normal"
				vim.notify("filebuf: saved", vim.log.levels.INFO)
			end)
			if not ok and not tostring(result):match("validation failed") then
				-- Unexpected error: extract a clean one-line message from the
				-- traceback so the user isn't faced with a wall of paths.
				local msg = tostring(result)
				-- Take the last meaningful line (the actual error), skipping
				-- stack-trace lines that start with a tab or "./".
				for line in msg:gmatch("[^\n]+") do
					local trimmed = line:match("^%s*(.*)%s*$")
					if not trimmed:match("^[\t%.]") and not trimmed:match("^%[C]") then
						msg = trimmed
					end
				end
				vim.notify(
					string.format("filebuf: save error — %s\nNothing was saved; your files are unchanged.", msg),
					vim.log.levels.ERROR
				)
			end

			prof.stop() -- save_filebuf
		end,
	})

	-- Cleanup find-mode session if buffer is deleted/unloaded.
	vim.api.nvim_create_autocmd({ "BufDelete", "BufUnload" }, {
		group = group,
		buffer = buf,
		callback = function()
			find.cleanup(buf)
		end,
	})

	vim.b[buf].filebuf_rebuilding = nil
	vim.bo[buf].modified = false

	if prof.enabled then
		prof.report()
	end
	prof.stop()
end

--- Setup entry point.  Merges `opts` into config and registers commands.
---@param opts? filebuf.Config
function M.setup(opts)
	opts = opts or {}
	local merged = vim.tbl_deep_extend("force", config, opts)
	for k, v in pairs(merged) do
		config[k] = v -- mutate in place so all modules see the update
	end

	config.define_highlights()

	-- Hijack netrw so directory opens use filebuf instead.
	if config.hijack_netrw then
		require("filebuf.hijack").setup()
	end

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
	vim.api.nvim_create_user_command("FilebufSortMethod", function(args)
		local buf = vim.api.nvim_get_current_buf()
		if not vim.b[buf] or not vim.b[buf].filebuf_root then
			vim.notify("filebuf: not in a filebuf buffer", vim.log.levels.WARN)
			return
		end
		local method = args.args and args.args:match("^%s*(%S+)%s*$")
		if method and vim.tbl_contains(SORT_METHODS, method) then
			config.sort_method = method
			refresh_buffer(buf)
			vim.notify("filebuf: sort by " .. method, vim.log.levels.INFO)
		else
			vim.notify(
				"filebuf: unknown sort method '" .. method .. "'. Valid: " .. table.concat(SORT_METHODS, ", "),
				vim.log.levels.ERROR
			)
		end
	end, { nargs = "?", desc = "Set or cycle sort method (type | name | modified | created)" })
	vim.api.nvim_create_user_command("FilebufFind", function(args)
		local buf = vim.api.nvim_get_current_buf()
		if not vim.b[buf] or not vim.b[buf].filebuf_root then
			vim.notify("filebuf: not in a filebuf buffer", vim.log.levels.WARN)
			return
		end
		if args.args == "" then
			vim.notify("filebuf: :FilebufFind needs a pattern", vim.log.levels.WARN)
			return
		end
		search.run(buf, args.args)
	end, { nargs = "?", desc = "Search the whole tree and reveal matching entries" })
	vim.api.nvim_create_user_command("FilebufSearchClear", function()
		search.clear(vim.api.nvim_get_current_buf())
	end, { desc = "Clear filebuf search match highlighting" })
end

return M
