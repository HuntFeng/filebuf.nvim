----------------------------------------------------------------------
-- Tree search for lazily-loaded entries.
--
-- Every directory is lazy-loaded, so entries not yet on screen are invisible
-- to native `/`.  Use `g/` (find mode) for interactive asynchronous search,
-- or `:FilebufFind <pattern>` to query the whole tree synchronously with
-- find(1) and load the ancestor chain of each hit — sibling subdirectories
-- along the way are listed but not expanded.  Matches are highlighted via
-- the decoration provider.
--
-- The pattern arrives as a Vim regex.  Vim-only atoms are stripped and any
-- remaining special characters are reduced to a literal substring, then
-- find(1) does a case-insensitive basename substring match.
--
-- Public API:
--   require("filebuf").search()                      -- skip ignored & hidden (default)
--   require("filebuf").search({ skip_ignored = false, skip_hidden = false })
----------------------------------------------------------------------
local config = require("filebuf.config")
local prof = require("filebuf.profiler")
local actions = require("filebuf.actions")
local buffer = require("filebuf.buffer")
local state = require("filebuf.state")
local render = require("filebuf.render")

local M = {}

-- Session state for async find mode: bufnr -> { job, timer, tree, pattern, saved_state, query_entries }
local sessions = {}

----------------------------------------------------------------------
-- Pattern translation
----------------------------------------------------------------------

--- Vim-only regex atoms that have no equivalent in plain-text search.
local VIM_ATOMS = { "\\v", "\\V", "\\m", "\\M", "\\<", "\\>", "\\zs", "\\ze" }

--- Regex metacharacters to strip for find(1) literal-substring matching.
local REGEX_META = "[%*%?%[%]%(%)%|%+%^%$%.]"

--- Translate a Vim search pattern into a plain substring for find(1).
---@param pattern string
---@return string|nil  needle for find -iname, or nil when empty
local function pattern_to_substring(pattern)
	local p = pattern

	-- Strip Vim-only atoms.
	for _, atom in ipairs(VIM_ATOMS) do
		p = p:gsub(vim.pesc(atom), "")
	end

	-- Strip \c / \C — find -iname is always case-insensitive.
	p = p:gsub("\\[cC]", "")

	-- Any remaining backslash escape is Vim-specific; strip the backslashes
	-- and treat the result as literal text.
	p = p:gsub("\\", "")

	-- Strip regex metacharacters — find -iname only does glob-style matching
	-- with *, ?, [], and we don't want to re-derive that from a Vim regex.
	p = p:gsub(REGEX_META, "")

	if p == "" then
		return nil
	end
	return p
end

--- Build a find(1) argv for searching under root.
---
--- When prune_dirs is given, ignored directories are pruned inline so their
--- subtrees are never stat-ed.  find's -o short-circuits: paths matching
--- -path … -prune are consumed by the left operand; everything else falls
--- through to -iname on the right.  Explicit -print keeps the implicit
--- default from leaking pruned directory names into the output.
---@param root       string
---@param needle     string  plain substring (already translated)
---@param prune_dirs? table   relative directory paths to prune
---@return string[]  argv ready for vim.system or vim.fn.systemlist
local function build_find_argv(root, needle, prune_dirs)
	local cmd = { "find", root }
	if prune_dirs and #prune_dirs > 0 then
		for _, dir in ipairs(prune_dirs) do
			local escaped = dir:gsub("([%*%?%[%]])", "\\%1")
			vim.list_extend(cmd, { "(", "-path", root .. "/" .. escaped, "-prune", ")", "-o" })
		end
	end
	-- Parenthesised with explicit -print: the implicit default -print only
	-- fires when the whole expression is true, which would leak pruned
	-- directories.  Wrapping the right operand in ( … -print ) keeps output
	-- restricted to actual -iname matches.
	vim.list_extend(cmd, { "(", "-mindepth", "1", "-iname", "*" .. needle .. "*", "-print", ")" })
	return cmd
end

----------------------------------------------------------------------
-- Synchronous query
----------------------------------------------------------------------

--- Query the tree under `root` for `pattern` synchronously.
---
--- Mirrors config so results can actually be displayed: hidden entries are
--- only searched when show_hidden is on — revealing a hit that filter_visible
--- would drop is pointless.
---@param root       string
---@param pattern    string  a Vim search pattern
---@param show_hidden? boolean  defaults to config.show_hidden
---@param prune_dirs?  table    relative directory paths to prune
---@return string[] paths  absolute paths
function M.query(root, pattern, show_hidden, prune_dirs)
	prof.start("search.query")
	if show_hidden == nil then
		show_hidden = config.show_hidden
	end

	local needle = pattern_to_substring(pattern)
	if not needle then
		prof.stop()
		return {}
	end

	local out = vim.fn.systemlist(build_find_argv(root, needle, prune_dirs))

	local paths = {}
	for _, raw in ipairs(out) do
		if raw ~= "" and vim.startswith(raw, root .. "/") then
			local rel = raw:sub(#root + 2)
			-- Skip hits under a dot-prefixed component when hidden entries
			-- aren't shown; reveal_path could not surface them anyway.
			local skip = false
			if not show_hidden then
				for component in rel:gmatch("[^/]+") do
					if component:sub(1, 1) == "." then
						skip = true
						break
					end
				end
			end
			if not skip then
				paths[#paths + 1] = raw
			end
		end
	end

	prof.stop()
	return paths
end

--- The path of the entry under the cursor, or nil.
local function cursor_path(buf)
	local entry = state.entry_at_cursor(buf)
	return entry and entry.path or nil
end

--- Reveal paths in the buffer, record matches, set the cursor and notify.
--- Shared by run() and search().
---@param buf         number
---@param paths       string[]
---@param pattern     string
---@param keep_cursor string|nil  when set and equal to a revealed path, leave cursor there
---@return number  how many matches were revealed
local function _reveal(buf, paths, pattern, keep_cursor)
	prof.start("search._reveal")
	local entries = actions.reveal_paths(buf, paths)
	prof.stop()
	if #entries == 0 then
		vim.notify(
			string.format("filebuf: %d match(es) for '%s', none reachable in the current view", #paths, pattern),
			vim.log.levels.WARN
		)
		return 0
	end

	local matches = {}
	for _, e in ipairs(entries) do
		matches[e.path] = true
	end
	local st = state.get(buf)
	if st then
		st.matches = matches
	end

	-- Cursor: if it already sits on a match (the native search having just
	-- jumped there), keep it — revealing shifted the line, not the entry.
	-- Otherwise go to the topmost match.
	table.sort(entries, function(a, b)
		return a.lnum < b.lnum
	end)
	local target = entries[1]
	if keep_cursor and matches[keep_cursor] then
		for _, e in ipairs(entries) do
			if e.path == keep_cursor then
				target = e
				break
			end
		end
	end
	vim.api.nvim_win_set_cursor(0, { target.lnum, 0 })
	vim.cmd("normal! zz")

	local msg = string.format("filebuf: %d match(es) for '%s'", #entries, pattern)
	if #entries < #paths then
		msg = msg .. string.format(" — %d hidden/unreachable hit(s) skipped", #paths - #entries)
	end
	vim.notify(msg, vim.log.levels.INFO)

	prof.stop()
	return #entries
end

--- Search, reveal every hit's ancestor chain, highlight the matches and place
--- the cursor on one of them.
---
--- Always queries the tree, even when the pattern already matches on screen:
--- finding an entry in the buffer says nothing about how many more are still
--- unloaded on disk.
---
--- @/ is left alone — the caller (e.g. :FilebufFind) owns it, and the user's
--- pattern still matches the freshly-revealed basename lines, so n/N keep
--- working.
---@param buf     number
---@param pattern string  a Vim search pattern
---@param opts?   table   { respect_ignored?: boolean }
---@return number  how many matches were revealed
function M.run(buf, pattern, opts)
	prof.start("search.run")
	opts = opts or {}
	local respect_ignored = opts.respect_ignored
	if respect_ignored == nil then
		respect_ignored = true
	end

	local root = state.root(buf)
	if not root then
		prof.stop()
		return 0
	end

	-- Whether the pattern matches something already on screen.  Only used to
	-- decide whether silence is appropriate: a Vim regex that matches buffer
	-- text but no basename (say "^ *b") legitimately yields no disk hits, and
	-- complaining about it would be wrong.
	local matched_locally = vim.fn.search(pattern, "nw") ~= 0
	local was_on = cursor_path(buf)

	M.clear(buf)

	local st = state.get(buf)
	local show_hidden = st and st.show_hidden

	-- Build prune list when the user wants to respect ignored entries.
	-- Independent of show_hidden: respect_ignored=false means search everything.
	local prune_dirs = nil
	if respect_ignored then
		local _, ignored_dirs = require("filebuf.git").build_ignore_set(root)
		prune_dirs = ignored_dirs
	end

	local paths = M.query(root, pattern, show_hidden, prune_dirs)
	if #paths == 0 then
		if not matched_locally then
			vim.notify("filebuf: pattern not found: " .. pattern, vim.log.levels.WARN)
		end
		prof.stop()
		return 0
	end

	local n = _reveal(buf, paths, pattern, was_on)
	prof.stop()
	return n
end

--- Drop the highlighted match set for `buf`.
---@param buf number
function M.clear(buf)
	local st = state.get(buf)
	if st then
		st.matches = nil
	end
end

--- Public search API.  Opens filebuf at cwd if not already in one, then enters
--- async find mode.  Ignored directories are pruned by default so their
--- subtrees are never stat-ed — pass `respect_ignored = false` to search
--- everything.
---
--- Bind this to a key in your config:
---   vim.keymap.set("n", "g/", function()
---     require("filebuf").search()
---   end, { desc = "filebuf: search tree" })
---
---@param opts? table  { skip_hidden?: boolean }
function M.search(opts)
	opts = opts or {}
	local skip_hidden = opts.skip_hidden
	if skip_hidden == nil then
		skip_hidden = true
	end

	local buf = vim.api.nvim_get_current_buf()
	if not state.is_filebuf(buf) then
		-- Not in a filebuf — open one at cwd first.
		require("filebuf").open()
		buf = vim.api.nvim_get_current_buf()
		if not state.is_filebuf(buf) then
			return
		end
	end

	M.enter(buf, { skip_hidden = skip_hidden })
end

----------------------------------------------------------------------
-- Tree building (find mode)
----------------------------------------------------------------------

--- Insert an absolute path into the tree, creating intermediate dir nodes.
--- No is_dir parameter — find(1) doesn't mark directories.  When a previously
--- inserted leaf node turns out to be a directory (because another result
--- appears inside it), the node is upgraded from "file" to "dir".
local function tree_insert(tree, root, abs_path)
	local rel = abs_path:sub(#root + 2) -- strip "root/"
	local parts = {}
	for part in rel:gmatch("[^/]+") do
		parts[#parts + 1] = part
	end

	local node = tree
	for i, part in ipairs(parts) do
		local is_final = i == #parts
		if not node.children[part] then
			local part_type = is_final and "file" or "dir"
			node.children[part] = { type = part_type, children = {} }
		elseif not is_final and node.children[part].type == "file" then
			-- Matched directory now has a child matched inside it — upgrade.
			node.children[part].type = "dir"
		end
		node = node.children[part]
	end
end

--- Flatten the tree into an entry list, sorted dirs-first + alphabetically.
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
-- Async query via vim.system (find)
----------------------------------------------------------------------

local function query_async(root, pattern, on_line, on_done, prune_dirs)
	local needle = pattern_to_substring(pattern)
	if not needle then
		on_done()
		return
	end

	local argv = build_find_argv(root, needle, prune_dirs)
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
					if line ~= "" and vim.startswith(line, root .. "/") then
						on_line(line)
					end
				end
			end
		end,
	}, function()
		-- Process any remaining partial line.
		if stdout_buffer ~= "" and vim.startswith(stdout_buffer, root .. "/") then
			on_line(stdout_buffer)
		end
		-- Schedule the callback in the main event loop (vim.system's on_exit
		-- runs in a fast event context where nvim_buf_is_valid isn't allowed).
		vim.schedule(on_done)
	end)

	return job
end

----------------------------------------------------------------------
-- Find mode render
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
-- Enter / exit find mode
----------------------------------------------------------------------

--- Enter async find mode.
---@param buf  number
---@param opts? table  { skip_hidden?: boolean }
function M.enter(buf, opts)
	local st = state.get(buf)
	if not st then
		return
	end
	local root = st.root

	opts = opts or {}
	local skip_hidden = opts.skip_hidden
	if skip_hidden == nil then
		skip_hidden = true
	end

	-- Cancel any in-flight deep scan so find mode and the snap-load
	-- completion don't race on the same buffer.
	render.cancel_deep_scan(buf)

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

	-- Build prune list from ignore set when respecting ignored entries.
	local prune_dirs = nil
	if skip_hidden then
		local _, ignored_dirs = require("filebuf.git").build_ignore_set(root)
		prune_dirs = ignored_dirs
	end

	-- Start async find query.
	session.job = query_async(root, pattern, function(path)
		if not sessions[buf] then
			return
		end
		tree_insert(sessions[buf].tree, root, path)
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
	end, prune_dirs)

	-- Bind <Esc> to exit find mode (buffer-local, scoped to this session).
	vim.keymap.set("n", "<Esc>", function()
		M.exit(buf)
	end, { buffer = buf, desc = "filebuf: exit find mode" })
end

--- Exit find mode, restoring the snapshot saved on entry.
---@param buf number
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
			-- During BufUnload / BufDelete the buffer may no longer be
			-- modifiable — pcall so the cleanup path does not error.
			local ok = pcall(render.entries, buf, saved.entries, saved.open_folds)
			if ok then
				vim.bo[buf].modified = saved.modified
			end
		end

		st.mode = "normal"
	end

	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		vim.api.nvim_set_option_value("winbar", "Normal", { win = win })
	end

	-- Delete the <Esc> mapping so it doesn't shadow normal-mode <Esc>.
	pcall(vim.keymap.del, "n", "<Esc>", { buffer = buf })
end

--- Clean up find-mode session on buffer delete/unload.
---@param buf number
function M.cleanup(buf)
	if sessions[buf] then
		M.exit(buf)
	end
end

return M
