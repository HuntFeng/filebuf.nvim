----------------------------------------------------------------------
-- filebuf — edit the filesystem as an editable buffer.
--
-- The tree is rendered into one buffer with indent-based folding; edits are
-- diffed against disk and applied on :w.  The buffer text is the source of
-- truth: it holds names, types and structure, and filebuf.state indexes only
-- the one thing a line cannot carry — its absolute path.
--
-- This file wires the modules together and exposes the public API; the heavy
-- lifting lives in:
--   state (per-buffer index) / render (the only writer of buffer text)
--   scan / buffer / sync / git / decoration
--   actions (public fold & lazy-expand API)
----------------------------------------------------------------------
local config = require("filebuf.config")
local prof = require("filebuf.profiler")
local buffer = require("filebuf.buffer")
local sync = require("filebuf.sync")
local decoration = require("filebuf.decoration")
local actions = require("filebuf.actions")
local search = require("filebuf.search")
local find = require("filebuf.find")
local state = require("filebuf.state")
local render = require("filebuf.render")

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

--- Per-buffer state accessor (root, index, expanded set).  Exposed for tests
--- and for user scripts that need to resolve a line to an entry.
---@see filebuf.state
M.state = state

--- Enable/disable the profiler; report to :messages.
function M.profile(enable)
	prof.set_enabled(enable)
end
function M.profile_report()
	return prof.report()
end

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------

local SORT_METHODS = { "type", "name", "modified", "created" }

--- Toggle show_hidden and re-render, preserving the cursor entry and fold state.
---
--- Unsaved edits survive: they are diffed against the disk state for the *old*
--- filter, then replayed onto the freshly scanned tree for the new one — the
--- same shape as rebasing a patch.  Sampling disk on both sides is what removed
--- the need for a long-lived clean snapshot to diff against later.
---@param buf number
local function toggle_hidden(buf)
	prof.start("toggle_hidden")
	local st = state.get(buf)
	if not st then
		prof.stop()
		return
	end

	local cursor_entry = state.entry_at_cursor(buf)
	local cursor_path = cursor_entry and cursor_entry.path

	local ops
	if vim.bo[buf].modified then
		local buf_entries = state.entries(buf)
		ops = sync.compute_diff(buf_entries, render.scan(buf))

		if #ops.errors > 0 then
			sync.report_errors(buf, ops.errors)
			vim.notify("filebuf: fix errors before toggling hidden files", vim.log.levels.WARN)
			prof.stop()
			return
		end
		-- Clear stale diagnostics from a previously failed save.
		pcall(vim.diagnostic.reset, sync.diag_ns, buf)
	end

	local open_dirs = state.open_dirs(buf)
	config.show_hidden = not config.show_hidden

	if ops then
		-- Replay the edits onto the newly visible tree, then render the result.
		local entries = render.scan(buf)
		sync.apply_ops_to_entries(entries, ops)
		render.entries(buf, entries, open_dirs)
		vim.bo[buf].modified = true
	else
		render.tree(buf, { open_dirs = open_dirs })
	end

	-- Restore the cursor to the same entry (accounts for shifted line numbers).
	if cursor_path then
		local lnum = state.lnum_of(buf, cursor_path)
		if lnum then
			pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
		end
	end

	vim.notify("filebuf: hidden files " .. (config.show_hidden and "shown" or "hidden"), vim.log.levels.INFO)
	prof.stop()
end

--- Set up buffer-local keymaps from config.
---@param buf number
local function setup_keymaps(buf)
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
			actions.save_fold_state(buf, state.root(buf))
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

--- True when the buffer text still matches the last render exactly.
---
--- A clean :w is the common case, and comparing the parsed buffer positionally
--- against the disk scan settles it in a couple of milliseconds instead of
--- running the full rename-matching diff.
---@param buf_entries  table[]
---@param disk_entries table[]
---@return boolean
local function identical(buf_entries, disk_entries)
	if #buf_entries ~= #disk_entries then
		return false
	end
	for i = 1, #buf_entries do
		local a, b = buf_entries[i], disk_entries[i]
		if a.path ~= b.path or a.type ~= b.type then
			return false
		end
	end
	return true
end

--- Parse, diff against disk, validate, apply, re-render.
---@param buf number
local function save_buffer(buf)
	prof.start("save_filebuf")
	local st = state.get(buf)
	if not st then
		prof.stop()
		return
	end
	local dir = st.root

	local ok, result = pcall(function()
		local buf_entries = buffer.parse_buffer(buf, dir)

		-- In find mode the diff is scoped to the query results, so entries that
		-- simply didn't match aren't mistaken for deletions.  Otherwise the
		-- baseline is disk as it is right now, for exactly the scope on screen.
		local disk_entries = find.query_entries(buf) or render.scan(buf)

		if identical(buf_entries, disk_entries) then
			pcall(vim.diagnostic.reset, sync.diag_ns, buf)
			vim.bo[buf].modified = false
			return
		end

		local ops = sync.compute_diff(buf_entries, disk_entries)

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
				return
			end
		end

		prof.start("save.apply_ops")
		sync.apply_ops(ops)
		prof.stop() -- save.apply_ops

		-- A save in find mode commits the edits, so drop back to the full tree.
		if st.mode == "find" then
			find.exit(buf)
		end

		search.clear(buf)
		render.tree(buf, { keep_view = true })
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
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

--- Open the filebuf browser rooted at `dir` (default: cwd).
---
--- With config.eager_load the whole tree is scanned up front (capped by
--- eager_max_entries) so every entry is a real buffer line and Vim's `/` can
--- find it; directories still start folded, so the view is the same.  With
--- eager_load off, only the root's children are loaded and each directory's
--- children appear when it is expanded or when a search reveals a path.
---
--- Edits apply to disk only on :w; type mismatches block the save.
---@param dir string|nil
function M.open(dir)
	prof.start("open_filebuf")
	dir = (dir or vim.fn.getcwd()):gsub("/$", "") -- normalize trailing slash

	-- If a filebuf already exists and is a real filebuf (not a hollow
	-- session-restored shell), switch to it and re-render at the new root.
	local existing_buf = vim.fn.bufnr("Filebuf")
	if existing_buf ~= -1 and vim.api.nvim_buf_is_valid(existing_buf) then
		if state.is_filebuf(existing_buf) then
			local st = state.init(existing_buf, dir)
			st.eager = config.eager_load and true or false
			state.attach(existing_buf)
			vim.api.nvim_set_current_buf(existing_buf)
			local closed = actions.closed[dir]
			render.tree(existing_buf, {
				open_dirs = closed and function(path)
					return not closed[path]
				end or nil,
			})
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
	vim.bo[buf].filetype = "filebuf"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].buflisted = false

	local st = state.init(buf, dir)
	st.eager = config.eager_load and true or false
	state.attach(buf)

	setup_keymaps(buf)

	-- Manual folding: each directory + descendants form a fold, closed
	-- initially.  Window options go first so the render's fold work sees them.
	-- Unexpanded directories have no children on screen and therefore no fold —
	-- the trailing "/" is their only cue.
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

	-- Restore saved fold state.  What was persisted is the *closed* set, so any
	-- directory the user hadn't closed reopens and anything newly revealed
	-- defaults to closed.
	local closed = actions.closed[dir]
	render.tree(buf, {
		open_dirs = closed and function(path)
			return not closed[path]
		end or nil,
	})

	-- Auto-focus the file that was being edited before :Filebuf.  When lazy,
	-- its ancestors aren't loaded yet, so reveal_path expands the chain down to
	-- it (opening folds on the way) before we place the cursor.
	if config.auto_focus_current_file and current_file ~= "" and vim.startswith(current_file, dir .. "/") then
		local target = actions.reveal_path(buf, vim.fn.resolve(current_file)) or actions.reveal_path(buf, current_file)
		if target then
			pcall(vim.api.nvim_win_set_cursor, 0, { target.lnum, 0 })
			vim.cmd("normal! zz")
		end
	end

	local group = vim.api.nvim_create_augroup("filebuf_edit_" .. buf, { clear = true })
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = group,
		buffer = buf,
		callback = function()
			save_buffer(buf)
		end,
	})

	-- Drop find-mode session and per-buffer state when the buffer goes away.
	vim.api.nvim_create_autocmd({ "BufDelete", "BufUnload" }, {
		group = group,
		buffer = buf,
		callback = function()
			find.cleanup(buf)
			state.clear(buf)
		end,
	})

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

	--- Resolve the current buffer as a filebuf, or warn and return nil.
	local function current_filebuf()
		local buf = vim.api.nvim_get_current_buf()
		if state.is_filebuf(buf) then
			return buf
		end
		vim.notify("filebuf: not in a filebuf buffer", vim.log.levels.WARN)
		return nil
	end

	vim.api.nvim_create_user_command("Filebuf", function()
		M.open()
	end, { desc = "Open filebuf listing buffer" })

	vim.api.nvim_create_user_command("FilebufToggleHidden", function()
		local buf = current_filebuf()
		if buf then
			toggle_hidden(buf)
		end
	end, { desc = "Toggle visibility of hidden (dot) files in filebuf" })

	vim.api.nvim_create_user_command("FilebufSortMethod", function(args)
		local buf = current_filebuf()
		if not buf then
			return
		end
		local method = args.args and args.args:match("^%s*(%S+)%s*$")
		if method and vim.tbl_contains(SORT_METHODS, method) then
			config.sort_method = method
			render.tree(buf, { keep_view = true })
			vim.notify("filebuf: sort by " .. method, vim.log.levels.INFO)
		else
			vim.notify(
				"filebuf: unknown sort method '" .. tostring(method) .. "'. Valid: " .. table.concat(SORT_METHODS, ", "),
				vim.log.levels.ERROR
			)
		end
	end, { nargs = "?", desc = "Set or cycle sort method (type | name | modified | created)" })

	vim.api.nvim_create_user_command("FilebufFind", function(args)
		local buf = current_filebuf()
		if not buf then
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
