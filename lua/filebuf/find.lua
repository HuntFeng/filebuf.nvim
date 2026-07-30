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
--
-- Entering find mode snapshots the buffer's entry list and exiting renders that
-- snapshot back, so unsaved edits survive the round trip verbatim.  There is no
-- need to replay a diff onto a shadow tree, which is what this used to do.
----------------------------------------------------------------------
local search = require("filebuf.search")
local actions = require("filebuf.actions")
local buffer = require("filebuf.buffer")
local state = require("filebuf.state")
local render = require("filebuf.render")

local M = {}

-- Session state: bufnr -> { job, timer, tree, pattern, saved_state, query_entries }
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

-- Flatten the tree into an entry list, sorted dirs-first + alphabetically.
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
		entries[#entries + 1] = {
			name = name,
			type = node.type,
			path = path,
			indent = indent,
			-- Dot-prefixed names still dim in find mode; without this the results
			-- lost every decoration the normal tree has.
			is_hidden = (name:sub(1, 1) == ".") or nil,
		}

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
	}, function()
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

local function draw(buf)
	local session = sessions[buf]
	if not session or not session.tree then
		return
	end

	local entries = tree_flatten(session.tree, state.root(buf), "", 0)
	-- Scoped baseline for save diffing: unmatched files must not look deleted.
	session.query_entries = entries
	render.entries(buf, entries, nil)
	vim.cmd("silent! normal! zR")
	vim.cmd("silent! normal! zx")
end

--- The entry list find mode is currently showing, or nil outside find mode.
--- Used as the :w diff baseline so a save in find mode only touches the
--- entries that are actually on screen.
---@param buf number
---@return table[]|nil
function M.query_entries(buf)
	local session = sessions[buf]
	return session and session.query_entries or nil
end

----------------------------------------------------------------------
-- Enter find mode
----------------------------------------------------------------------

function M.enter(buf)
	local st = state.get(buf)
	if not st then
		return
	end
	local root = st.root

	-- Cancel any in-flight deep scan so find mode and the snap-load
	-- completion don't race on the same buffer.
	require("filebuf.render").cancel_deep_scan(buf)

	-- Tear down any existing session so re-pressing g/ restarts cleanly.
	if sessions[buf] then
		M.exit(buf)
	end

	-- Prompt for the search pattern.
	local pattern = vim.fn.input("Filebuf find: ")
	if pattern == "" then
		return
	end

	-- Record the pattern so n / N can navigate between matches.
	vim.fn.setreg("/", pattern)

	-- Snapshot normal-mode state for restore on <Esc>.  state.entries reflects
	-- unsaved edits, so restoring it puts the user's text back as it was.
	local saved_state = {
		entries = state.entries(buf),
		modified = vim.bo[buf].modified,
		open_folds = vim.deepcopy(actions.open_folds[root] or {}),
	}

	sessions[buf] = {
		pattern = pattern,
		saved_state = saved_state,
		tree = { type = "dir", children = {} },
		dirty = false,
		timer = nil,
		job = nil,
		query_entries = {},
	}

	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		vim.api.nvim_set_option_value("winbar", "Find: " .. pattern, { win = win })
	end
	st.mode = "find"

	-- Clear the buffer and start async query.
	st.rendering = true
	buffer.without_undo(buf, function()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
	end)
	st.rendering = false
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
				draw(buf)
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
			draw(buf)
			-- Place cursor on the first match if there is one, otherwise leave it at the top.
			vim.cmd("silent! normal! n")
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

	sessions[buf] = nil

	local st = state.get(buf)
	if st then
		local saved = session.saved_state
		if saved and saved.entries and #saved.entries > 0 then
			render.entries(buf, saved.entries, saved.open_folds)
			-- Unsaved edits made before entering find mode are still unsaved.
			vim.bo[buf].modified = saved.modified
		end

		st.mode = "normal"
	end

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
