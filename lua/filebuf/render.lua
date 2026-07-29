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

	-- Restore fold state (find mode preserves the open set from before).
	-- restore_folds records the resulting state as it goes.
	require("filebuf.actions").restore_folds(buf, open_dirs, entries)

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

	-- Which directories to leave open afterwards.  No need to read the folds
	-- back off the buffer: actions.open_folds has tracked them all along, and
	-- it is equally valid on a fresh open, where there are no folds to read.
	local actions = require("filebuf.actions")
	local open_dirs = opts.open_dirs or actions.open_folds[st.root]

	-- Clear search-match highlighting (line numbers mean nothing after re-render).
	st.matches = nil

	-- 1. Scan: find → buffer lines ----------------------------------
  prof.start("render.tree.find_to_lines")
	git.clear_ignore_cache(st.root)
	local lines, truncated_dirs, ignore_set = scan.find_to_lines(st.root)
	if not lines then
		vim.notify("filebuf: find(1) failed — is the directory accessible?", vim.log.levels.ERROR)
		prof.stop()
		return
	end
	st.truncated_dirs = truncated_dirs or {}
	st.ignore_set = ignore_set
  prof.stop()

	-- 2. Write buffer lines -----------------------------------------
  prof.start("render.tree.nvim_buf_set_lines")
	st.rendering = true
	buffer.without_undo(buf, function()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	end)
	buffer.clear_undo(buf)
	st.rendering = false
	vim.bo[buf].modified = false
  prof.stop()

	-- Invalidate the path→lnum cache — line numbers shifted.
	st._by_path_dirty = true

	-- 3. Folds ------------------------------------------------------
	-- 'foldexpr' derives the fold ranges from the lines just written, so
	-- this only resets which of them are open — and records that as it goes.
	prof.start("render.tree.restore_folds")
	actions.restore_folds(buf, open_dirs)
	prof.stop()

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
