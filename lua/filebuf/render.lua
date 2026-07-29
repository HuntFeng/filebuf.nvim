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
local snapshot = require("filebuf.snapshot")

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

	-- Find mode writes its own scoped entry list, which does not correspond to
	-- snap.view, so snapshot-backed lookups must not be used until the next
	-- full render.
	st.snap_clean = false
	st._by_path_dirty = true

	-- Restore fold state (find mode preserves the open set from before).
	-- restore_folds records the resulting state as it goes.
	require("filebuf.actions").restore_folds(buf, open_dirs, entries)

	-- Re-trigger async git status; the existing map stays visible meanwhile.
	if config.git_status then
		git.get_status_map_async(st.root, buf)
	end

	prof.stop()
end

----------------------------------------------------------------------
-- Re-projection: cached rows → buffer, no disk read
----------------------------------------------------------------------

--- Rewrite the buffer from the snapshot already in memory.
---
--- No find(1), no git ls-files, no re-parse of the buffer -- just a new
--- projection of the rows the last scan produced.  This is what makes
--- toggling hidden files and changing sort method cheap.
---
--- Returns false when the cache cannot answer, in which case the caller
--- should fall back to M.tree:
---   * no snapshot yet (nothing rendered)
---   * the buffer has unsaved edits (they would be discarded)
---   * hidden entries are wanted but the scan used find -prune, so the
---     ignored subtrees were never collected in the first place
---
---@param buf   number
---@param opts? table  { show_hidden?: boolean, sort_method?: string, keep_view?: boolean }
---@return boolean handled
function M.reproject(buf, opts)
	opts = opts or {}
	local st = state.get(buf)
	if not st or not st.snap or st.snap.n == 0 then
		return false
	end
	if vim.bo[buf].modified then
		return false
	end

	local show_hidden = opts.show_hidden
	if show_hidden == nil then
		show_hidden = st.show_hidden
	end
	local snap = st.snap
	if show_hidden and snap.pruned then
		-- The ignored rows are not in the cache; only a rescan can supply them.
		return false
	end

	prof.start("render.reproject")
	local view = opts.keep_view ~= false and vim.fn.winsaveview() or nil
	local method = opts.sort_method or config.sort_method

	prof.start("render.reproject.project")
	snapshot.project(snap, method, show_hidden)
	prof.stop()

	prof.start("render.reproject.lines")
	local lines = snapshot.lines(snap)
	prof.stop()

	st.matches = nil
	st.show_hidden = show_hidden

	prof.start("render.reproject.nvim_buf_set_lines")
	st.rendering = true
	buffer.without_undo(buf, function()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	end)
	buffer.clear_undo(buf)
	st.rendering = false
	vim.bo[buf].modified = false
	prof.stop()

	st._by_path_dirty = true
	st.snap_clean = true
	st.dirty_lo, st.dirty_hi = nil, nil
	st.truncated_dirs = snapshot.truncated_paths(snap)

	prof.start("render.reproject.restore_folds")
	require("filebuf.actions").restore_folds(buf, opts.open_dirs or require("filebuf.actions").open_folds[st.root])
	prof.stop()

	if view then
		vim.fn.winrestview(view)
	end

	prof.stop()
	return true
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

	-- 1. Scan: find → snapshot → buffer lines -----------------------
	-- The snapshot outlives this render: it is reused as-is for toggles,
	-- re-sorts and the post-save refresh, and it is what serves foldexpr and
	-- path resolution while the buffer is unedited.
	prof.start("render.tree.scan")
	-- The ignore cache used to be cleared here, which meant a guaranteed
	-- `git ls-files` process per render.  It is now invalidated on the events
	-- that can actually change the answer -- a save, a debounced FocusGained,
	-- or :FilebufRefresh -- see filebuf.setup.
	if opts.refresh_ignore then
		git.clear_ignore_cache(st.root)
	end
	st.snap = st.snap or snapshot.new(st.root)

	local show_hidden = opts.show_hidden
	if show_hidden == nil then
		show_hidden = st.show_hidden
	end
	st.show_hidden = show_hidden

	local lines, ignore_set = scan.scan_into(st.snap, st.root, { show_hidden = show_hidden })
	if not lines then
		vim.notify("filebuf: find(1) failed — is the directory accessible?", vim.log.levels.ERROR)
		prof.stop()
		return
	end
	st.truncated_dirs = snapshot.truncated_paths(st.snap)
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

	-- The buffer now matches snap.view line for line, so lookups may be served
	-- from the snapshot.  The first edit clears this (see state.attach) and
	-- everything falls back to reading the buffer.
	st.snap_clean = true
	st.dirty_lo, st.dirty_hi = nil, nil

	-- 3. Folds ------------------------------------------------------
	-- 'foldexpr' derives the fold ranges from the lines just written, so
	-- this only resets which of them are open — and records that as it goes.
	prof.start("render.tree.restore_folds")
	actions.restore_folds(buf, open_dirs)
	prof.stop()

	-- 4. Git status (async) -----------------------------------------
	-- The previous map is deliberately left in place while the refresh runs:
	-- clearing it blanked every status column for the duration of the job,
	-- which read as a flash on each render.
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
