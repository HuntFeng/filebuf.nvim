----------------------------------------------------------------------
-- filebuf - edit the filesystem as an editable buffer.
--
-- This file wires the modules together and exposes the public API.
----------------------------------------------------------------------
local config = require("filebuf.config")
local prof = require("filebuf.profiler")
local buffer = require("filebuf.buffer")
local sync = require("filebuf.sync")
local snapshot = require("filebuf.snapshot")
local decoration = require("filebuf.decoration")
local fold = require("filebuf.fold")
local search = require("filebuf.search")
local scan = require("filebuf.scan")
local state = require("filebuf.state")
local render = require("filebuf.render")
local copy = require("filebuf.copy")

local M = {}
M.config = config

----------------------------------------------------------------------
-- Keymaps
----------------------------------------------------------------------

--- Set up buffer-local keymaps from config.
---@param buf number
local function setup_keymaps(buf)
	local km = config.keymaps

	-- Entry-level actions (need cursor → entry resolution).
	local ENTRY_KEYMAPS = {
		open_file = { M.open_entry, "filebuf: open file" },
		open_or_toggle = { M.open_or_toggle, "filebuf: open file / toggle dir" },
		preview = { M.preview_entry, "filebuf: preview file" },
	}
	for name, def in pairs(ENTRY_KEYMAPS) do
		local key = km[name]
		if key and key ~= "" then
			local fn = def[1]
			local desc = def[2]
			vim.keymap.set("n", key, function()
				local entry = state.entry_at_cursor(buf)
				if entry then
					fn(buf, entry)
				end
			end, { buffer = buf, desc = desc })
		end
	end

	-- Buffer-level actions (no entry needed).  Each def is { fn, desc } or
	-- { fn, desc, opts } for parameterised calls.
	local BUF_KEYMAPS = {
		find_mode = { M.find_mode, "filebuf: find mode" },
		find_mode_full = { M.find_mode, "filebuf: find mode", { skip_hidden = false } },
		toggle_hidden = { M.toggle_hidden, "filebuf: toggle hidden files" },
		close_filebuf = { M.close, "filebuf: close" },
		sort_by_name = { M.sort_by, "filebuf: sort by name", { method = "name" } },
		sort_by_type = { M.sort_by, "filebuf: sort by type", { method = "type" } },
		sort_by_ctime = { M.sort_by, "filebuf: sort by ctime", { method = "created" } },
		sort_by_mtime = { M.sort_by, "filebuf: sort by mtime", { method = "modified" } },
		paste = { M.paste_entries, "filebuf: paste yanked entries" },
	}
	for name, def in pairs(BUF_KEYMAPS) do
		local key = km[name]
		if key and key ~= "" then
			local fn = def[1]
			local desc = def[2]
			local opts = def[3]
			vim.keymap.set("n", key, function()
				if opts then
					fn(buf, opts)
				else
					fn(buf)
				end
			end, { buffer = buf, desc = desc })
		end
	end

	-- Yank works on the cursor entry in normal mode and on the selection in
	-- visual mode, so it needs both, and neither table models two modes.
	if km.copy and km.copy ~= "" then
		vim.keymap.set("n", km.copy, function()
			require("filebuf.copy").yank_at_cursor(buf)
		end, { buffer = buf, desc = "filebuf: yank entry (copy)" })
		vim.keymap.set("x", km.copy, function()
			-- line("v") is only meaningful while the selection is live, so read
			-- the range before leaving visual mode.
			local a, b = vim.fn.line("v"), vim.fn.line(".")
			vim.cmd("normal! \27")
			require("filebuf.copy").yank(buf, math.min(a, b), math.max(a, b))
		end, { buffer = buf, desc = "filebuf: yank entries (copy)" })
	end
end

--- Apply the window-local fold and display options to the current window.
--- Folds are computed by 'foldexpr' from the buffer's indentation, so any
--- window showing a filebuf needs these set before it renders.
local function set_window_options()
	-- 'foldexpr' first: setting 'foldmethod' triggers the first evaluation.
	vim.wo.foldexpr = "v:lua.FilebufFoldExpr()"
	vim.wo.foldmethod = "expr"
	vim.wo.foldlevel = 0
	vim.wo.foldenable = true
	vim.wo.foldcolumn = "auto:9"
	vim.wo.foldtext = "v:lua.FilebufFoldText()"
	vim.wo.winhighlight = "Folded:FilebufFoldLine"
	vim.opt_local.fillchars:append({
		foldopen = "\226\150\188",
		foldclose = "\226\150\182",
		fold = " ",
	})
end

--- Build a confirmation message from diff ops and ask the user to confirm.
---@param ops  table
---@param root string
---@return boolean
local function confirm_save(ops, root)
	local lines = { "Apply the following changes to the filesystem?" }

	local function rel(p)
		return p:sub(#root + 2)
	end

	local MAX_SHOWN = 20

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

	if ops.copied and #ops.copied > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = string.format("Copy (%d):", #ops.copied)
		for i = 1, math.min(#ops.copied, MAX_SHOWN) do
			local c = ops.copied[i]
			lines[#lines + 1] = "  c " .. rel(c.src) .. " -> " .. rel(c.dst.path)
		end
		if #ops.copied > MAX_SHOWN then
			lines[#lines + 1] = string.format("  ... and %d more", #ops.copied - MAX_SHOWN)
		end
	end

	if #ops.renamed > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = string.format("Rename (%d):", #ops.renamed)
		for i = 1, math.min(#ops.renamed, MAX_SHOWN) do
			local r = ops.renamed[i]
			lines[#lines + 1] = "  ~ " .. rel(r.old.path) .. " -> " .. rel(r.new.path)
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

	-- Nothing has been edited since the last render, so the buffer describes
	-- the tree the snapshot already holds and there is nothing to sync.  Bails
	-- before the buffer parse and before the baseline find(1), which together
	-- were the whole cost of a reflexive :w on a large tree.
	--
	-- This also removes a hazard: the old path diffed the unchanged buffer
	-- against a fresh scan, so a file created outside Neovim since the render
	-- showed up as a deletion the user never asked for.
	if st.snap_clean and not vim.bo[buf].modified and st.mode ~= "find" then
		st.matches = nil
		pcall(vim.diagnostic.reset, sync.diag_ns, buf)
		prof.stop()
		return
	end

	local ok, result = pcall(function()
		local buf_entries = buffer.parse_buffer(buf, dir)

		-- Two siblings with the same name cannot both exist, so this is checked
		-- on the full entry list — before the copy split, which is exactly the
		-- operation that makes a clash easy to produce.
		local pre_errors = sync.check_duplicates(buf_entries)

		-- Pull the pasted lines out: they are copies of a known source, not
		-- entries to be diffed.  Left in, the diff's rename phases would happily
		-- pair a pasted line with an unrelated same-named disk entry and turn
		-- the copy into a move.
		local copies, diff_entries, copy_errors = copy.split(buf, buf_entries)
		local flagged = {}
		for _, err in ipairs(pre_errors) do
			flagged[err.lnum] = true
		end
		for _, err in ipairs(copy_errors) do
			-- A duplicate already reported on this line says the same thing.
			if not flagged[err.lnum] then
				pre_errors[#pre_errors + 1] = err
			end
		end

		-- In find mode the diff is scoped to the query results.
		-- Otherwise the snapshot (already in memory from the last render) is
		-- the disk baseline.  A fresh find(1) is only the last-resort fallback
		-- when there is no snapshot yet.
		local disk_entries = search.query_entries(buf)
			or (st.snap and snapshot.to_entries(st.snap, st.show_hidden))
			or scan.scan_disk_entries(st.root)

		prof.start("save_filebuf.identical")
		if disk_entries and #pre_errors == 0 and #copies == 0 and identical(diff_entries, disk_entries) then
			prof.stop()
			pcall(vim.diagnostic.reset, sync.diag_ns, buf)
			vim.bo[buf].modified = false
			return
		end
		prof.stop()

		if not disk_entries then
			vim.notify("filebuf: cannot read disk state - is find(1) available?", vim.log.levels.ERROR)
			return
		end

		local ops = sync.compute_diff(diff_entries, disk_entries)
		ops.copied = copies
		for _, err in ipairs(ops.errors) do
			pre_errors[#pre_errors + 1] = err
		end
		ops.errors = pre_errors

		if #ops.errors > 0 then
			sync.report_errors(buf, ops.errors)
			error("filebuf: validation failed")
		end
		pcall(vim.diagnostic.reset, sync.diag_ns, buf)

		prof.start("save_filebuf.pre_apply")
		local has_changes = #ops.renamed > 0 or #ops.created > 0 or #ops.deleted > 0 or #ops.copied > 0
		if config.save_confirmation and has_changes then
			if not confirm_save(ops, dir) then
				prof.stop()
				vim.notify("filebuf: save cancelled", vim.log.levels.INFO)
				return
			end
			require("filebuf.git").get_status_map_async(st.root, buf) -- refresh git status after cancel
		end
		prof.stop()

		prof.start("save_filebuf.apply_ops")
		sync.apply_ops(ops)
		prof.stop()

		-- The yank has been consumed.
		if #ops.copied > 0 then
			copy.clear(buf)
		end

		if st.mode == "find" then
			search.exit(buf)
		end

		search.clear(buf)

		-- Replay the ops onto the cached rows and re-project, instead of a
		-- third find(1) for one save.  Safe because these ops just succeeded,
		-- so the resulting tree is known rather than inferred.  apply_ops
		-- declines the cases it cannot reproduce exactly (see snapshot.lua),
		-- and then the full rescan below is what runs.
		-- A recursive copy brings in paths the ops never named, so the cache
		-- cannot replay it; those saves take the full rescan below.
		local applied = false
		if st.snap and st.mode ~= "find" and #ops.copied == 0 then
			applied = snapshot.apply_ops(st.snap, ops, st.ignore_set)
				and render.reproject(buf, { keep_view = true, force = true })
		end
		if not applied then
			-- The ops may have created or removed ignored paths, so the ignore
			-- set is re-read here even though renders no longer clear it.
			render.tree(buf, { keep_view = true, refresh_ignore = true })
		end
		vim.notify("filebuf: saved", vim.log.levels.INFO)
	end)

	if not ok and not tostring(result):match("validation failed") then
		local msg = tostring(result)
		for line in msg:gmatch("[^\n]+") do
			local trimmed = line:match("^%s*(.*)%s*$")
			if not trimmed:match("^[\t%.]") and not trimmed:match("^%[C]") then
				msg = trimmed
			end
		end
		vim.notify(
			string.format("filebuf: save error - %s\nNothing was saved; your files are unchanged.", msg),
			vim.log.levels.ERROR
		)
	end

	prof.stop()
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
--- Open a file or follow a symlink.  For symlinks that point to
--- directories, open a new filebuf at the target.
---@param buf   number
---@param entry table
function M.open_entry(buf, entry)
	if not entry or entry.type == "dir" then
		return -- use fold actions for directories
	end

	local target = vim.loop.fs_realpath(entry.path) or entry.path
	if entry.type == "link" and vim.fn.isdirectory(target) == 1 then
		-- Symlink → directory: open a new filebuf.
		require("filebuf").open(target)
	elseif vim.fn.filereadable(target) == 1 then
		vim.cmd("edit " .. vim.fn.fnameescape(target))
	else
		vim.notify("Cannot read: " .. entry.path, vim.log.levels.WARN)
	end
end

--- Handle <CR> / open_or_toggle: toggle fold on directories, open files.
--- Returns true if the entry was handled.
---@param buf   number
---@param entry table
---@return boolean
function M.open_or_toggle(buf, entry)
	if not entry then
		return false
	end

	if entry.type == "dir" then
		vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
		vim.cmd("normal! za")
	else
		M.open_entry(buf, entry)
	end
	return true
end

--- Preview a file entry in a floating window (like LSP hover).
--- Bound to K by default.
---@param buf   number
---@param entry table
function M.preview_entry(buf, entry)
	require("filebuf.preview").show(buf, entry)
end

--- Paste the yanked entries at the cursor.  The lines appear immediately;
--- the filesystem copy happens on :w, like every other filebuf edit.
---@param buf number
function M.paste_entries(buf)
	copy.paste(buf)
end

--- Enter interactive find mode on a filebuf buffer.
---@param buf number
function M.find_mode(buf)
	require("filebuf.search").enter(buf)
end

--- Sort a filebuf buffer by method.
---@param buf   number
---@param opts  table  { method: string }
function M.sort_by(buf, opts)
	local method = opts and opts.method
	if not method then
		return
	end
	local sort = require("filebuf.sort")
	if not vim.tbl_contains(sort.METHODS, method) then
		vim.notify(
			"filebuf: unknown sort method '" .. method .. "'. Valid: " .. table.concat(sort.METHODS, ", "),
			vim.log.levels.ERROR
		)
		return
	end

	config.sort_method = method
	local st = state.get(buf)
	if not st then
		return
	end

	local render = require("filebuf.render")
	if not render.reproject(buf, { sort_method = method }) then
		local entries = buffer.parse_buffer(buf, st.root)
		local open_dirs = M.open_folds[st.root]
		local sorted = sort.apply(entries, method)
		if sorted ~= entries and #sorted > 0 then
			render.entries(buf, sorted, open_dirs)
		end
	end
	vim.notify("filebuf: sort by " .. method, vim.log.levels.INFO)
end

--- Toggle hidden entries for this buffer.
---@param buf number
function M.toggle_hidden(buf)
	prof.start("toggle_hidden")

	prof.start("toggle_hidden.guard")
	local st = state.get(buf)
	if not st then
		prof.stop()
		prof.stop()
		return
	end

	if vim.bo[buf].modified then
		vim.notify("filebuf: buffer modified - save or discard edits before toggling hidden files", vim.log.levels.WARN)
		prof.stop()
		prof.stop()
		return
	end

	local cursor_entry = state.entry_at_cursor(buf)
	local cursor_path = cursor_entry and cursor_entry.path
	local want = not st.show_hidden
	state.set_show_hidden(st.root, want)
	prof.stop() -- toggle_hidden.guard

	local render = require("filebuf.render")
	prof.start("toggle_hidden.reproject")
	local reprojected = render.reproject(buf, { show_hidden = want })
	prof.stop() -- toggle_hidden.reproject

	if not reprojected then
		prof.start("toggle_hidden.tree")
		render.tree(buf, { show_hidden = want, keep_view = true })
		prof.stop() -- toggle_hidden.tree
	end

	prof.start("toggle_hidden.cursor")
	if cursor_path then
		local lnum = state.lnum_of(buf, cursor_path)
		if lnum then
			pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
		end
	end
	prof.stop() -- toggle_hidden.cursor

	vim.notify("filebuf: hidden files " .. (st.show_hidden and "shown" or "hidden"), vim.log.levels.INFO)

	if prof.enabled then
		prof.report()
	end
	prof.stop() -- toggle_hidden
end

--- Close a filebuf buffer.  Fold state is captured by the BufDelete
--- autocmd, so the caller doesn't need to snapshot anything.
---@param buf number
function M.close(buf)
	vim.api.nvim_buf_delete(buf, { force = true })
end

--- Open the filebuf browser rooted at `dir` (default: cwd).
---@param dir string|nil
function M.open(dir)
	prof.start("open_filebuf")
	dir = (dir or vim.fn.getcwd()):gsub("/$", "")

	local existing_buf = vim.fn.bufnr("Filebuf")
	if existing_buf ~= -1 and vim.api.nvim_buf_is_valid(existing_buf) then
		if state.is_filebuf(existing_buf) then
			fold.capture_fold_state(existing_buf)
			local st = state.init(existing_buf, dir)
			state.attach(existing_buf)
			vim.api.nvim_set_current_buf(existing_buf)
			set_window_options()
			-- Fold preferences for `dir` persist in actions.open_folds, which
			-- render.tree picks up on its own.
			render.tree(existing_buf)
			prof.stop()
			return
		end
		pcall(vim.api.nvim_buf_delete, existing_buf, { force = true })
	end

	local current_file = vim.api.nvim_buf_get_name(0)

	local buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_name(buf, "Filebuf")
	vim.bo[buf].filetype = "filebuf"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].buflisted = false

	local st = state.init(buf, dir)
	state.attach(buf)

	setup_keymaps(buf)

	vim.api.nvim_set_current_buf(buf)
	set_window_options()
	render.set_winbar(buf, "Normal")

	render.tree(buf, { shallow_first = true })

	if config.auto_focus_current_file and current_file ~= "" and vim.startswith(current_file, dir .. "/") then
		local target = fold.reveal_path(buf, vim.fn.resolve(current_file)) or fold.reveal_path(buf, current_file)
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

	vim.api.nvim_create_autocmd({ "BufDelete", "BufUnload" }, {
		group = group,
		buffer = buf,
		callback = function()
			-- Persist fold state so reopen at the same root remembers
			-- which folds the user had open.
			fold.capture_fold_state(buf)
			-- Cancel the deep scan first so the buffer is writable for find
			-- cleanup (restoring saved entries during BufUnload).
			render.cancel_deep_scan(buf)
			search.cleanup(buf)
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
		config[k] = v
	end

	config.define_highlights()

	if config.hijack_netrw then
		require("filebuf.hijack").setup()
	end

	vim.api.nvim_set_decoration_provider(decoration.ns, {
		on_start = decoration.on_start,
		on_win = decoration.on_win,
	})

	-- The fold expression caches these to keep its per-line cost down.
	vim.api.nvim_create_autocmd("OptionSet", {
		group = vim.api.nvim_create_augroup("filebuf_indent_options", { clear = true }),
		pattern = { "shiftwidth", "tabstop", "expandtab" },
		callback = function()
			fold.invalidate_indent_cache()
		end,
	})

	-- Renders no longer clear the gitignore cache, so something has to. Coming
	-- back to Neovim is the moment the tree is most likely to have changed
	-- underneath us; debounced so a flurry of focus events costs one refresh.
	local focus_timer = nil
	vim.api.nvim_create_autocmd("FocusGained", {
		group = vim.api.nvim_create_augroup("filebuf_refresh_on_focus", { clear = true }),
		callback = function()
			for _, b in ipairs(state.buffers()) do
				local st = state.get(b)
				if st and st.mode == "normal" and vim.api.nvim_buf_is_valid(b) and not vim.bo[b].modified then
					render.set_winbar(b, "Refreshing...")
				end
			end

			if focus_timer then
				focus_timer:stop()
			end
			focus_timer = vim.defer_fn(function()
				focus_timer = nil
				for _, b in ipairs(state.buffers()) do
					local st = state.get(b)
					if st and vim.api.nvim_buf_is_valid(b) and not vim.bo[b].modified then
						if st.mode == "normal" then
							require("filebuf.git").clear_ignore_cache(st.root)
							render.tree(b, { keep_view = true, refresh_ignore = true })
							render.set_winbar(b, "Normal")
						end
					end
				end
			end, 200)
		end,
	})

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
			M.toggle_hidden(buf)
		end
	end, { desc = "Toggle visibility of hidden (dot) files in filebuf" })

	vim.api.nvim_create_user_command("FilebufSortMethod", function(args)
		local buf = current_filebuf()
		if not buf then
			return
		end
		local method = args.args and args.args:match("^%s*(%S+)%s*$")
		if method then
			M.sort_by(buf, { method = method })
		end
	end, { nargs = "?", desc = "Set sort method (type | name | modified | created)" })

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
end

return M
