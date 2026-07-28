----------------------------------------------------------------------
-- Async find mode (g/) — search the tree with live streaming results.
--
-- Pressing g/ enters find mode: a one-shot pattern prompt, then fd runs
-- asynchronously and streams results into an incremental tree (dirs +
-- ancestors only, no unrelated siblings). Results render as they arrive
-- (batched ~80ms to avoid O(n²) re-renders). <Esc> exits back to normal mode.
--
-- Session state (job, timer, tree) is held module-locally by bufnr, since
-- libuv handles aren't valid buffer-variable values.
----------------------------------------------------------------------
local config = require("filebuf.config")
local search = require("filebuf.search")
local actions = require("filebuf.actions")
local buffer = require("filebuf.buffer")
local sync = require("filebuf.sync")
local scan = require("filebuf.scan")
local line_mod = require("filebuf.line")

local M = {}

-- Session state: bufnr -> { job, timer, tree, pattern, saved_state }
local sessions = {}

----------------------------------------------------------------------
-- Tree building
----------------------------------------------------------------------

-- Insert an absolute path into the tree, creating intermediate dir nodes.
-- fd marks dirs with a trailing "/"; caller passes is_dir = path ends with "/".
local function tree_insert(tree, root, abs_path, is_dir)
	local rel = abs_path:sub(#root + 2) -- strip "root/"
	local parts = {}
	for part in rel:gmatch("[^/]+") do
		parts[#parts + 1] = part
	end

	local node = tree
	for i, part in ipairs(parts) do
		local is_final = i == #parts
		local part_type = (is_final and is_dir) and "dir" or (is_final and "file" or "dir")
		if not node.children[part] then
			node.children[part] = { type = part_type, children = {} }
		end
		node = node.children[part]
	end
end

-- Flatten the tree into a display entry list, sorted dirs-first + alphabetically.
local function tree_flatten(tree, root, current_path, indent)
	local entries = {}
	local names = {}
	for name in pairs(tree.children) do
		names[#names + 1] = name
	end
	table.sort(names, function(a, b)
		local a_is_dir = tree.children[a].type == "dir"
		local b_is_dir = tree.children[b].type == "dir"
		if a_is_dir ~= b_is_dir then
			return a_is_dir
		end
		return a < b
	end)

	for _, name in ipairs(names) do
		local node = tree.children[name]
		local path = current_path == "" and (root .. "/" .. name) or (current_path .. "/" .. name)
		local entry = {
			name = name,
			type = node.type,
			path = path,
			indent = indent,
		}
		entries[#entries + 1] = entry

		if node.type == "dir" and next(node.children) then
			local sub = tree_flatten(node, root, path, indent + 1)
			for _, e in ipairs(sub) do
				entries[#entries + 1] = e
			end
		end
	end

	return entries
end

----------------------------------------------------------------------
-- Async query via vim.system (fd only, no find fallback)
----------------------------------------------------------------------

function M.query_async(root, pattern, on_line, on_done)
	local fd = search.fd_cmd()
	if not fd then
		vim.notify("filebuf find: fd is required for async find mode", vim.log.levels.WARN)
		on_done()
		return
	end

	local argv = search.build_fd_argv(root, pattern)
	if not argv then
		on_done()
		return
	end

	local stdout_buffer = ""
	local job = vim.system(argv, {
		stdout = function(_, data)
			if data then
				stdout_buffer = stdout_buffer .. data
				local lines = vim.split(stdout_buffer, "\n")
				-- Keep the incomplete final line in the buffer.
				stdout_buffer = lines[#lines]
				for i = 1, #lines - 1 do
					local line = lines[i]
					if line ~= "" then
						local path = line:sub(-1) == "/" and line:sub(1, -2) or line
						if vim.startswith(path, root .. "/") then
							local is_dir = line:sub(-1) == "/"
							on_line(path, is_dir)
						end
					end
				end
			end
		end,
	}, function(result)
		-- Process any remaining partial line.
		if stdout_buffer ~= "" then
			local path = stdout_buffer:sub(-1) == "/" and stdout_buffer:sub(1, -2) or stdout_buffer
			if vim.startswith(path, root .. "/") then
				local is_dir = stdout_buffer:sub(-1) == "/"
				on_line(path, is_dir)
			end
		end
		-- Schedule the callback in the main event loop (vim.system's on_exit
		-- runs in a fast event context where nvim_buf_is_valid isn't allowed).
		vim.schedule(on_done)
	end)

	return job
end

----------------------------------------------------------------------
-- Render
----------------------------------------------------------------------

local function render(buf)
	local session = sessions[buf]
	if not session or not session.tree then
		return
	end

	local entries = tree_flatten(session.tree, vim.b[buf].filebuf_root, "", 0)
	for i, entry in ipairs(entries) do
		entry.lnum = i
	end

	vim.b[buf].filebuf_display_entries = entries
	vim.b[buf].filebuf_query_entries = entries -- scoped baseline for save diffing

	buffer.without_undo(buf, function()
		local lines = {}
		for _, entry in ipairs(entries) do
			lines[#lines + 1] = line_mod.format_line(entry)
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	end)

	-- Rebuild folds so nested matches can be folded/unfolded normally.
	actions.rebuild_folds(buf, entries)

	-- Rendering the query tree shouldn't mark the buffer as modified.
	vim.bo[buf].modified = false
end

----------------------------------------------------------------------
-- Enter find mode
----------------------------------------------------------------------

function M.enter(buf)
	local root = vim.b[buf].filebuf_root
	if not root then
		return
	end

	-- Tear down any existing session so re-pressing g/ restarts cleanly.
	if sessions[buf] then
		M.exit(buf)
	end

	-- Prompt for the search pattern.
	local pattern = vim.fn.input("Filebuf find: ")
	if pattern == "" then
		return
	end

	-- Snapshot normal-mode state for restore on <Esc>.
	local saved_state = {
		display_entries = vim.deepcopy(vim.b[buf].filebuf_display_entries or {}),
		modified = vim.bo[buf].modified,
		fold_state = vim.deepcopy(actions.closed[root] or {}),
	}

	-- If the buffer has unsaved edits, merge them into filebuf_all_entries
	-- before entering find mode (same pattern as toggle_hidden).
	if vim.bo[buf].modified then
		local buf_entries = buffer.parse_buffer(buf)
		local baseline = saved_state.display_entries
		local ops = sync.compute_diff(buf_entries, baseline)

		if #ops.errors > 0 then
			sync.report_errors(buf, ops.errors)
			vim.notify("filebuf: fix errors before entering find mode", vim.log.levels.WARN)
			return
		end

		local all_entries = vim.b[buf].filebuf_all_entries
		if all_entries then
			sync.apply_ops_to_entries(all_entries, ops)
		end
	end

	-- Initialize session.
	sessions[buf] = {
		pattern = pattern,
		saved_state = saved_state,
		tree = { type = "dir", children = {} },
		dirty = false,
		timer = nil,
		job = nil,
	}

	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		vim.api.nvim_set_option_value("winbar", "Find: " .. pattern, { win = win })
	end
	vim.b[buf].filebuf_mode = "find"

	-- Clear the buffer and start async query.
	buffer.without_undo(buf, function()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
	end)
	vim.bo[buf].modified = false

	-- Batched render: timer fires every ~80ms to avoid O(n) re-renders per hit.
	local session = sessions[buf]
	session.timer = vim.uv.new_timer()
	session.timer:start(
		80,
		80,
		vim.schedule_wrap(function()
			if not sessions[buf] or not session.dirty then
				return
			end
			session.dirty = false
			if vim.api.nvim_buf_is_valid(buf) then
				render(buf)
			end
		end)
	)

	-- Start async fd query.
	session.job = M.query_async(root, pattern, function(path, is_dir)
		if not sessions[buf] then
			return
		end
		tree_insert(sessions[buf].tree, root, path, is_dir)
		sessions[buf].dirty = true
	end, function()
		-- Job done: stop timer and flush one final render.
		if sessions[buf] and sessions[buf].timer then
			sessions[buf].timer:stop()
		end
		if vim.api.nvim_buf_is_valid(buf) then
			render(buf)
		end
	end)

	-- Bind <Esc> to exit find mode (buffer-local, scoped to this session).
	vim.keymap.set("n", "<Esc>", function()
		M.exit(buf)
	end, { buffer = buf, desc = "filebuf: exit find mode" })
end

----------------------------------------------------------------------
-- Exit find mode
----------------------------------------------------------------------

function M.exit(buf)
	local session = sessions[buf]
	if not session then
		return
	end

	-- Kill job and timer.
	if session.job then
		session.job:kill(9)
	end
	if session.timer then
		session.timer:stop()
	end

	-- Restore snapshotted normal-mode state.
	local root = vim.b[buf].filebuf_root
	if root and session.saved_state then
		local saved = session.saved_state

		-- Re-render the saved display entries.
		local saved_entries = saved.display_entries
		if saved_entries and #saved_entries > 0 then
			local lines = {}
			for _, entry in ipairs(saved_entries) do
				lines[#lines + 1] = line_mod.format_line(entry)
			end
			buffer.without_undo(buf, function()
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			end)

			-- Restore fold state.
			local open_dirs = {}
			for _, e in ipairs(saved_entries) do
				if e.type == "dir" and not saved.fold_state[e.path] then
					open_dirs[e.path] = true
				end
			end
			actions.rebuild_folds(buf, saved_entries, open_dirs)
		end

		vim.b[buf].filebuf_display_entries = saved_entries
		vim.b[buf].filebuf_query_entries = nil

		-- Restore modified flag (unsaved edits made before entering find mode
		-- are still unsaved).
		vim.bo[buf].modified = saved.modified
	end

	-- Clean up session and mode.
	sessions[buf] = nil
	-- vim.b[buf].filebuf_mode = "normal"
	-- vim.wo.winbar = "Normal"
	vim.b[buf].filebuf_mode = "normal"
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		vim.api.nvim_set_option_value("winbar", "Normal", { win = win })
	end

	-- Delete the <Esc> mapping so it doesn't shadow normal-mode <Esc>.
	pcall(vim.keymap.del, "n", "<Esc>", { buffer = buf })
end

----------------------------------------------------------------------
-- Cleanup on buffer delete/unload
----------------------------------------------------------------------

function M.cleanup(buf)
	if sessions[buf] then
		M.exit(buf)
	end
end

return M
