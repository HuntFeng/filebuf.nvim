----------------------------------------------------------------------
-- The one place buffer text is produced.
--
-- Everything funnels through M.tree().  There is no incremental path —
-- expanding a directory re-renders the whole buffer, which sounds wasteful
-- and isn't: in eager mode the tree is capped by max_depth (default 20),
-- and in lazy mode it's only as big as what the user opened.
--
-- The index (parallel arrays) is gone.  Lines go straight into the buffer;
-- path resolution walks up from the line to its ancestors on demand.
----------------------------------------------------------------------
local config = require("filebuf.config")
local prof = require("filebuf.profiler")
local line_mod = require("filebuf.line")
local buffer = require("filebuf.buffer")
local scan = require("filebuf.scan")
local state = require("filebuf.state")
local git = require("filebuf.git")

local M = {}

----------------------------------------------------------------------
-- Entries → buffer (kept for find-mode rendering)
----------------------------------------------------------------------

--- Render an explicit entry list into the buffer.  Used by find mode, which
--- builds its own in-memory entry tree scoped to the query results.
---@param buf       number
---@param entries   table[]
---@param open_dirs table|nil  set of dir paths to leave unfolded
function M.entries(buf, entries, open_dirs)
	local st = state.get(buf)
	if not st then
		return
	end
	prof.start("render.entries")

	local fmt = line_mod.formatter()
	local lines = {}
	for i, e in ipairs(entries) do
		e.lnum = i
		lines[i] = fmt(e)
	end

	st.rendering = true
	buffer.without_undo(buf, function()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	end)
	buffer.clear_undo(buf)
	st.rendering = false
	vim.bo[buf].modified = false

	-- Restore fold state (find mode preserves the closed set from before).
	local actions = require("filebuf.actions")
	actions.rebuild_folds(buf, entries, open_dirs)
	actions.save_fold_state(buf, st.root, entries)

	-- Clear and re-trigger async git status.
	st.git = nil
	if config.git_status then
		git.get_status_map_async(st.root, buf)
	end

	prof.stop()
end

----------------------------------------------------------------------
-- Main render: disk → buffer
----------------------------------------------------------------------

--- Re-read the tree from disk and render it into the buffer.
--- This is the single writer of buffer content in normal mode.
---@param buf   number
---@param opts? table  { keep_view?: boolean, open_dirs?: table }
function M.tree(buf, opts)
	opts = opts or {}
	local st = state.get(buf)
	if not st then
		return
	end
	prof.start("render.tree")

	local view = opts.keep_view and vim.fn.winsaveview() or nil

	-- Snapshot which directories are open before anything clobbers the folds.
	-- On a fresh open the buffer is empty, so the snapshot is empty too — we
	-- rely on the persisted fold state (actions.closed) instead.
	local open_dirs = opts.open_dirs
	if st._by_path and not st._by_path_dirty then
		if open_dirs == nil then
			open_dirs = state.open_dirs(buf)
		end
		require("filebuf.actions").save_fold_state(buf, st.root)
	end

	-- Clear search-match highlighting (line numbers mean nothing after re-render).
	st.matches = nil

	-- 1. Scan: find → buffer lines ----------------------------------
	git.clear_ignore_cache(st.root)
	local lines, truncated_dirs, ignore_set = scan.find_to_lines(st.root)
	if not lines then
		vim.notify("filebuf: find(1) failed — is the directory accessible?", vim.log.levels.ERROR)
		prof.stop()
		return
	end
	st.truncated_dirs = truncated_dirs or {}
	st.ignore_set = ignore_set

	-- 2. Write buffer lines -----------------------------------------
	st.rendering = true
	buffer.without_undo(buf, function()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	end)
	buffer.clear_undo(buf)
	st.rendering = false
	vim.bo[buf].modified = false

	-- Invalidate the path→lnum cache — line numbers shifted.
	st._by_path_dirty = true

	-- 3. Folds ------------------------------------------------------
	local actions = require("filebuf.actions")
	actions.create_folds_from_buffer(buf)
	if open_dirs then
		actions.open_folds(buf, open_dirs)
	end
	actions.save_fold_state(buf, st.root)

	-- 4. Git status (async) -----------------------------------------
	st.git = nil
	if config.git_status then
		git.get_status_map_async(st.root, buf)
	end

	-- 5. Warn on eager truncation -----------------------------------
	if st.truncated and not st.truncated_notified then
		st.truncated_notified = true
		vim.notify(
			string.format(
				"filebuf: stopped the eager scan at %d entries; deeper folders load on demand (use %s to search the rest)",
				config.eager_max_entries,
				tostring(config.keymaps.find_mode or "g/")
			),
			vim.log.levels.WARN
		)
	end

	if view then
		vim.fn.winrestview(view)
	end

	if prof.enabled then
		prof.report()
	end
	prof.stop()
end

return M
