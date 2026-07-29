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
local decoration = require("filebuf.decoration")
local actions = require("filebuf.actions")
local search = require("filebuf.search")
local find = require("filebuf.find")
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

--- Public, user-mutable configuration (see filebuf.config).
M.config = config

--- Public fold / lazy-expand / entry-open API.
M.actions = actions

--- Per-buffer state accessor (root, expanded set).  Exposed for tests
--- and for user scripts that need to resolve a line to an entry.
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

--- Recursively sort entries within each parent group.
--- Entries is a flat depth-first list; siblings at the same indent
--- level are sorted while preserving parent-child relationships.
---@param entries table[]
---@param cmp     fun(a: table, b: table): boolean
---@return table[]
local function hierarchical_sort(entries, cmp)
	---@param start_idx number
	---@param end_idx   number
	---@return table[]
	local function sort_range(start_idx, end_idx)
		if start_idx > end_idx then
			return {}
		end

		local base_indent = entries[start_idx].indent
		local result = {}
		local j = start_idx

		-- Collect siblings at base_indent within this range.
		local siblings = {}
		while j <= end_idx do
			if entries[j].indent == base_indent then
				siblings[#siblings + 1] = { idx = j, entry = entries[j] }
				j = j + 1
			elseif entries[j].indent > base_indent then
				j = j + 1 -- descendant of previous sibling, handled by recursion
			else
				break -- indent < base_indent: back to parent scope
			end
		end

		-- Compute each sibling's descendant range.
		for k = 1, #siblings do
			local sib = siblings[k]
			local next_start = (k < #siblings) and siblings[k + 1].idx or j
			sib.desc_end = next_start - 1
		end

		-- Sort siblings.
		if #siblings > 1 then
			table.sort(siblings, function(a, b)
				return cmp(a.entry, b.entry)
			end)
		end

		-- Output each sibling followed by its recursively sorted descendants.
		for _, sib in ipairs(siblings) do
			result[#result + 1] = sib.entry
			if sib.entry.type == "dir" and sib.idx + 1 <= sib.desc_end then
				local children = sort_range(sib.idx + 1, sib.desc_end)
				for _, child in ipairs(children) do
					result[#result + 1] = child
				end
			end
		end

		return result
	end

	if #entries == 0 then
		return {}
	end
	return sort_range(1, #entries)
end

--- Toggle show_hidden and re-render.  Because the buffer IS the data
--- store there is no edit-replay path; a fresh scan replaces the buffer
--- content.  Unsaved edits must be saved or discarded first.
---@param buf number
local function toggle_hidden(buf)
	prof.start("toggle_hidden")
	local st = state.get(buf)
	if not st then
		prof.stop()
		return
	end

	if vim.bo[buf].modified then
		vim.notify("filebuf: buffer modified - save or discard edits before toggling hidden files", vim.log.levels.WARN)
		prof.stop()
		return
	end

	local cursor_entry = state.entry_at_cursor(buf)
	local cursor_path = cursor_entry and cursor_entry.path
	local open_dirs = state.open_dirs(buf)
	config.show_hidden = not config.show_hidden

	render.tree(buf, { open_dirs = open_dirs })

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

	if km.toggle_hidden then
		vim.keymap.set("n", km.toggle_hidden, function()
			toggle_hidden(buf)
		end, { buffer = buf, desc = "filebuf: toggle hidden files" })
	end

	if km.close_filebuf then
		vim.keymap.set("n", km.close_filebuf, function()
			actions.save_fold_state(buf, state.root(buf))
			vim.api.nvim_buf_delete(buf, { force = true })
		end, { buffer = buf, desc = "filebuf: close" })
	end

	if km.find_mode then
		vim.keymap.set("n", km.find_mode, function()
			find.enter(buf)
		end, { buffer = buf, desc = "filebuf: find mode" })
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

	local ok, result = pcall(function()
		local buf_entries = buffer.parse_buffer(buf, dir)

		-- In find mode the diff is scoped to the query results.
		local disk_entries = find.query_entries(buf) or scan.scan_disk_entries(st.root)

		if disk_entries and identical(buf_entries, disk_entries) then
			pcall(vim.diagnostic.reset, sync.diag_ns, buf)
			vim.bo[buf].modified = false
			return
		end

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

		local has_changes = #ops.renamed > 0 or #ops.created > 0 or #ops.deleted > 0
		if config.save_confirmation and has_changes then
			if not confirm_save(ops, dir) then
				vim.notify("filebuf: save cancelled", vim.log.levels.INFO)
				return
			end
		end

		prof.start("save.apply_ops")
		sync.apply_ops(ops)
		prof.stop()

		if st.mode == "find" then
			find.exit(buf)
		end

		search.clear(buf)
		render.tree(buf, { keep_view = true })
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
	st.eager = config.eager_load and true or false
	state.attach(buf)

	setup_keymaps(buf)

	vim.api.nvim_set_current_buf(buf)
	vim.wo.foldmethod = "manual"
	vim.wo.foldenable = true
	vim.wo.foldcolumn = "auto:9"
	vim.wo.foldtext = "v:lua.FilebufFoldText()"
	vim.wo.winhighlight = "Folded:FilebufFoldLine"
	vim.opt_local.fillchars:append({
		foldopen = "\226\150\188",
		foldclose = "\226\150\182",
		fold = " ",
	})
	set_winbar(buf, "Normal")

	local closed = actions.closed[dir]
	render.tree(buf, {
		open_dirs = closed and function(path)
			return not closed[path]
		end or nil,
	})

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
			local st = state.get(buf)
			if st then
				local entries = buffer.parse_buffer(buf, st.root)
				local open_dirs = state.open_dirs(buf)

				-- Build comparator for the chosen method.
				local cmp = nil
				if method == "name" then
					cmp = function(a, b)
						return a.name:lower() < b.name:lower()
					end
				elseif method == "type" then
					local PRIO = { dir = 1, link = 2, file = 3 }
					cmp = function(a, b)
						local pa = PRIO[a.type] or 5
						local pb = PRIO[b.type] or 5
						if pa ~= pb then
							return pa < pb
						end
						return a.name:lower() < b.name:lower()
					end
				end

				if cmp then
					local sorted = hierarchical_sort(entries, cmp)
					if #sorted > 0 then
						render.entries(buf, sorted, open_dirs)
					end
				end
			end
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
