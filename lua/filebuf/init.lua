----------------------------------------------------------------------
-- filebuf - edit the filesystem as an editable buffer.
--
-- The buffer text is the source of truth: it holds names, types and
-- structure.  There is no in-memory index - the absolute path of any
-- line is derived on demand by walking up the buffer.
--
-- This file wires the modules together and exposes the public API.
----------------------------------------------------------------------
local config = require("filebuf.config")
local prof = require("filebuf.profiler")
local buffer = require("filebuf.buffer")
local sync = require("filebuf.sync")
local snapshot = require("filebuf.snapshot")
local decoration = require("filebuf.decoration")
local actions = require("filebuf.actions")
local search = require("filebuf.search")
local scan = require("filebuf.scan")
local state = require("filebuf.state")
local render = require("filebuf.render")

local M = {}

--- Set winbar on every window that displays `buf`.
---@param buf number
---@param text string
local function set_winbar(buf, text)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		vim.api.nvim_set_option_value("winbar", text, { win = win })
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

--- Public, user-mutable configuration (see filebuf.config).
M.config = config

--- Public fold / lazy-expand / entry-open API.
M.actions = actions

--- Per-buffer state accessor (root, expanded set).  Exposed for tests
--- and for user scripts that need to resolve a line to an entry.
M.state = state

--- Tree-wide search: prompts for a pattern, reveals every match.
---   require("filebuf").search()                  -- respect ignored (default)
---   require("filebuf").search({ skip_hidden = false })
M.search = actions.search

--- Enable/disable the profiler; report to :messages.
function M.profile(enable)
	prof.set_enabled(enable)
end
function M.profile_report()
	return prof.report()
end

----------------------------------------------------------------------
-- Keymaps
----------------------------------------------------------------------

--- Set up buffer-local keymaps from config.
---@param buf number
local function setup_keymaps(buf)
	local km = config.keymaps

	-- Entry-level actions (need cursor → entry resolution).
	local ENTRY_KEYMAPS = {
		open_file = { actions.open_entry, "filebuf: open file" },
		open_or_toggle = { actions.open_or_toggle, "filebuf: open file / toggle dir" },
		preview = { actions.preview_entry, "filebuf: preview file" },
	}
	for name, def in pairs(ENTRY_KEYMAPS) do
		local key = km[name]
		if key and key ~= "" then
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

	-- Buffer-level actions (no entry needed).  Each def is { fn, desc } or
	-- { fn, desc, opts } for parameterised calls.
	local BUF_KEYMAPS = {
		find_mode = { actions.find_mode, "filebuf: find mode" },
		toggle_hidden = { actions.toggle_hidden, "filebuf: toggle hidden files" },
		close_filebuf = { actions.close, "filebuf: close" },
		sort_by_name = { actions.sort_by, "filebuf: sort by name", { method = "name" } },
		sort_by_type = { actions.sort_by, "filebuf: sort by type", { method = "type" } },
		sort_by_ctime = { actions.sort_by, "filebuf: sort by ctime", { method = "created" } },
		sort_by_mtime = { actions.sort_by, "filebuf: sort by mtime", { method = "modified" } },
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

		-- In find mode the diff is scoped to the query results.
		-- Otherwise the snapshot (already in memory from the last render) is
		-- the disk baseline.  A fresh find(1) is only the last-resort fallback
		-- when there is no snapshot yet.
		local disk_entries = search.query_entries(buf)
			or (st.snap and snapshot.to_entries(st.snap, st.show_hidden))
			or scan.scan_disk_entries(st.root)

		prof.start("save_filebuf.identical")
		if disk_entries and identical(buf_entries, disk_entries) then
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

		local ops = sync.compute_diff(buf_entries, disk_entries)

		if #ops.errors > 0 then
			sync.report_errors(buf, ops.errors)
			error("filebuf: validation failed")
		end
		pcall(vim.diagnostic.reset, sync.diag_ns, buf)

		prof.start("save_filebuf.pre_apply")
		local has_changes = #ops.renamed > 0 or #ops.created > 0 or #ops.deleted > 0
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

		if st.mode == "find" then
			search.exit(buf)
		end

		search.clear(buf)

		-- Replay the ops onto the cached rows and re-project, instead of a
		-- third find(1) for one save.  Safe because these ops just succeeded,
		-- so the resulting tree is known rather than inferred.  apply_ops
		-- declines the cases it cannot reproduce exactly (see snapshot.lua),
		-- and then the full rescan below is what runs.
		local applied = false
		if st.snap and st.mode ~= "find" then
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

--- Open the filebuf browser rooted at `dir` (default: cwd).
---@param dir string|nil
function M.open(dir)
	prof.start("open_filebuf")
	dir = (dir or vim.fn.getcwd()):gsub("/$", "")

	local existing_buf = vim.fn.bufnr("Filebuf")
	if existing_buf ~= -1 and vim.api.nvim_buf_is_valid(existing_buf) then
		if state.is_filebuf(existing_buf) then
			actions.capture_fold_state(existing_buf)
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
	set_winbar(buf, "Normal")

	render.tree(buf, { shallow_first = true })

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

	vim.api.nvim_create_autocmd({ "BufDelete", "BufUnload" }, {
		group = group,
		buffer = buf,
		callback = function()
			-- Persist fold state so reopen at the same root remembers
			-- which folds the user had open.
			actions.capture_fold_state(buf)
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
			actions.invalidate_indent_cache()
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
					set_winbar(b, "Refreshing...")
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
							set_winbar(b, "Normal")
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
			actions.toggle_hidden(buf)
		end
	end, { desc = "Toggle visibility of hidden (dot) files in filebuf" })

	vim.api.nvim_create_user_command("FilebufSortMethod", function(args)
		local buf = current_filebuf()
		if not buf then
			return
		end
		local method = args.args and args.args:match("^%s*(%S+)%s*$")
		if method then
			actions.sort_by(buf, { method = method })
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
