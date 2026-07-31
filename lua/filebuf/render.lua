----------------------------------------------------------------------
-- Buffer writing.
--
-- The one place filebuf writes the buffer text.  The main path is M.tree():
-- find(1) → snapshot → lines, with a shallow-first variant that renders the
-- top levels immediately and finishes the tree with an async deep scan.
-- Re-renders that need no disk read (toggle hidden, re-sort, post-save
-- refresh) go through M.reproject, which re-projects the cached snapshot;
-- find mode renders its own scoped entry list via M.entries, and the deep
-- scan completion lands via M.finish.
--
-- While the buffer is unedited, path resolution and fold levels are served
-- from the snapshot (filebuf.snapshot); an edit marks the snapshot dirty and
-- every lookup falls back to walking the buffer text, which is always
-- correct.
----------------------------------------------------------------------
local config = require("filebuf.config")
local prof = require("filebuf.profiler")
local line_mod = require("filebuf.line")
local buffer = require("filebuf.buffer")
local scan = require("filebuf.scan")
local state = require("filebuf.state")
local git = require("filebuf.git")
local snapshot = require("filebuf.snapshot")
local actions = require("filebuf.actions")

local M = {}

-- Shallow-first render depth.  Internal — not user-configurable.
local SNAP_DEPTH = 5

-- Track in-flight deep scans: buf → { job_id, serial }
local deep_scans = {}

--- Cancel any active deep scan for `buf`.  Safe to call when none is running.
---@param buf number
function M.cancel_deep_scan(buf)
	local info = deep_scans[buf]
	if info then
		if info.job_id then
			pcall(vim.fn.jobstop, info.job_id)
		end
		deep_scans[buf] = nil
	end
	local st = state.get(buf)
	if st then
		st.deep_scan_job = nil
	end
end

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
	st.render_serial = st.render_serial + 1
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
---@param opts? table  { show_hidden?, sort_method?, keep_view?, force? }
---@return boolean handled
function M.reproject(buf, opts)
	opts = opts or {}
	local st = state.get(buf)
	if not st or not st.snap or st.snap.n == 0 then
		return false
	end
	-- Unsaved edits would be discarded by the rewrite below.  `force` is for
	-- the post-save path, where the edits have just been written to disk and
	-- the rows already reflect them.
	if vim.bo[buf].modified and not opts.force then
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
	-- Capture native fold state before the buffer rewrite destroys it.
	require("filebuf.actions").capture_fold_state(buf)
	st.rendering = true
	st.render_serial = st.render_serial + 1
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
-- Render tail: lines → buffer + folds + git + view
----------------------------------------------------------------------

--- Write lines into the buffer, restore folds, trigger git status, and
--- optionally restore a saved view.  The shared tail of M.tree() and the
--- deep-scan completion path.
---@param buf       number
---@param st        table    buffer state
---@param lines     string[]
---@param open_dirs table|nil
---@param view      table|nil winsaveview() snapshot
local function commit_render(buf, st, lines, open_dirs, view)
	prof.start("render.commit.nvim_buf_set_lines")
	st.rendering = true
	st.render_serial = st.render_serial + 1
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

	local actions = require("filebuf.actions")
	prof.start("render.commit.restore_folds")
	actions.restore_folds(buf, open_dirs)
	prof.stop()

	if config.git_status then
		git.get_status_map_async(st.root, buf)
	end

	if view then
		vim.fn.winrestview(view)
	end
end

--- Write pre-computed lines into the buffer (skip the scan step).
--- Used by the deep-scan completion path to finish a snap-load
--- transition without re-running find(1).
---@param buf       number
---@param lines     string[]
---@param open_dirs table|nil
---@param view      table|nil  from vim.fn.winsaveview()
function M.finish(buf, lines, open_dirs, view)
	local st = state.get(buf)
	if not st then
		return
	end
	commit_render(buf, st, lines, open_dirs, view)
end

----------------------------------------------------------------------
-- Deep scan completion
----------------------------------------------------------------------

--- Callback invoked when the async deep scan finishes.
--- Guards against staleness (the shallow view may have been replaced),
--- rebuilds the snapshot from the full output, and re-renders.
---@param buf            number
---@param capture_serial number  st.render_serial at shallow-render time
---@param output         string|nil  raw find stdout, or nil on failure
local function _handle_deep_scan_complete(buf, capture_serial, output)
	deep_scans[buf] = nil

	local st = state.get(buf)
	if not st or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	st.deep_scan_job = nil

	if not output then
		actions.set_winbar(buf, "Normal")
		vim.notify("filebuf: deep scan failed — showing partial tree", vim.log.levels.WARN)
		return
	end

	-- Guard: a newer render has already replaced the shallow view.
	if st.render_serial ~= capture_serial then
		actions.set_winbar(buf, "Normal")
		return
	end

	-- Guard: user edited the buffer during the deep scan.
	if vim.bo[buf].modified then
		actions.set_winbar(buf, "Normal")
		vim.notify(
			"filebuf: deep scan complete — buffer has unsaved edits, use :FilebufRefresh to load full tree",
			vim.log.levels.WARN
		)
		return
	end

	-- Guard: snapshot no longer matches the buffer (another safety).
	if not st.snap_clean then
		actions.set_winbar(buf, "Normal")
		return
	end

	-- Save cursor path so we can restore it after the re-render.
	local cursor_entry = state.entry_at_cursor(buf)
	local cursor_path = cursor_entry and cursor_entry.path

	-- Rebuild the snapshot from the full output.
	local _, ignored_dirs = git.build_ignore_set(st.root)
	local prune_dirs = (not st.show_hidden) and ignored_dirs or nil
	local pruned = prune_dirs ~= nil and #prune_dirs > 0

	snapshot.build(st.snap, output, st.ignore_set, pruned)
	snapshot.project(st.snap, config.sort_method, st.show_hidden)
	local lines = snapshot.lines(st.snap)

	-- Re-render: full buffer write, preserve folds + cursor position.
	local view = vim.fn.winsaveview()
	local open_dirs = require("filebuf.actions").open_folds[st.root]
	commit_render(buf, st, lines, open_dirs, view)

	-- Restore cursor to the same path (line numbers shifted).
	if cursor_path then
		local lnum = state.lnum_of(buf, cursor_path)
		if lnum then
			pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
		end
	end

	actions.set_winbar(buf, "Normal")
end

--- Shallow sync scan + kick off async deep scan.
---@param buf  number
---@param st   table   state for buf
---@param opts table   original opts passed to M.tree
local function _tree_shallow_then_deep(buf, st, opts)
	prof.start("render.tree.shallow")

	local actions = require("filebuf.actions")
	if not opts.open_dirs then
		actions.capture_fold_state(buf)
	end
	local open_dirs = opts.open_dirs or actions.open_folds[st.root]

	-- 1. Scan: shallow depth only ------------------------------------
	prof.start("render.tree.shallow.scan")
	st.snap = st.snap or snapshot.new(st.root)

	if opts.refresh_ignore then
		git.clear_ignore_cache(st.root)
	end

	local show_hidden = opts.show_hidden
	if show_hidden == nil then
		show_hidden = st.show_hidden
	end
	st.show_hidden = show_hidden

	local lines, ignore_set = scan.scan_into(st.snap, st.root, {
		show_hidden = show_hidden,
		maxdepth = SNAP_DEPTH,
	})
	if not lines then
		vim.notify("filebuf: find(1) failed — is the directory accessible?", vim.log.levels.ERROR)
		prof.stop()
		return
	end
	st.ignore_set = ignore_set
	prof.stop()

	-- 2. Write shallow lines (skip git status — deferred to deep). ---
	st.matches = nil
	commit_render(buf, st, lines, open_dirs, nil)
	prof.stop()

	-- 3. Kick off async deep scan ------------------------------------
	-- The buffer stays modifiable so the user can start editing
	-- immediately; if they do, the deep-scan completing will notice
	-- vim.bo[buf].modified and skip the update (keeping their edits).
	actions.set_winbar(buf, "Scanning...")
	local capture_serial = st.render_serial

	local _, ignored_dirs = git.build_ignore_set(st.root)
	local prune_dirs = (not show_hidden) and ignored_dirs or nil

	local job_id = scan.run_find_async(
		st.root,
		config.max_depth,
		prune_dirs,
		-- on_progress: update winbar with live entry count.
		function(count)
			if vim.api.nvim_buf_is_valid(buf) then
				actions.set_winbar(buf, string.format("Scanning... %d entries", count))
			end
		end,
		-- on_done: rebuild snapshot and re-render.
		function(output)
			_handle_deep_scan_complete(buf, capture_serial, output)
		end
	)

	if job_id then
		deep_scans[buf] = { job_id = job_id, serial = capture_serial }
		st.deep_scan_job = job_id
	else
		-- Non-GNU find: fall back to synchronous full-depth scan.
		actions.set_winbar(buf, "Normal")
		M.tree(buf, {
			keep_view = true,
			show_hidden = show_hidden,
			open_dirs = open_dirs,
		})
	end
end

----------------------------------------------------------------------
-- Main render: disk → buffer
----------------------------------------------------------------------

--- Re-read the tree from disk and render it into the buffer.
--- This is the single writer of buffer content in normal mode.
---@param buf   number
---@param opts? table  { keep_view?: boolean, open_dirs?: table, maxdepth?: number, shallow_first?: boolean, refresh_ignore?: boolean, show_hidden?: boolean }
function M.tree(buf, opts)
	opts = opts or {}
	local st = state.get(buf)
	if not st then
		return
	end
	prof.start("render.tree")

	-- Cancel any in-flight deep scan before we re-render.
	M.cancel_deep_scan(buf)

	if opts.shallow_first then
		prof.stop()
		return _tree_shallow_then_deep(buf, st, opts)
	end

	local view = opts.keep_view and vim.fn.winsaveview() or nil

	-- Which directories to leave open afterwards.  Capture native fold
	-- state now — the buffer rewrite in commit_render will destroy it.
	local actions = require("filebuf.actions")
	if not opts.open_dirs then
		actions.capture_fold_state(buf)
	end
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

	local lines, ignore_set = scan.scan_into(st.snap, st.root, {
		show_hidden = show_hidden,
		maxdepth = opts.maxdepth,
	})
	if not lines then
		vim.notify("filebuf: find(1) failed — is the directory accessible?", vim.log.levels.ERROR)
		prof.stop()
		return
	end
	st.ignore_set = ignore_set
	prof.stop()

	-- 2-4. Write lines, restore folds, git status, restore view ------
	commit_render(buf, st, lines, open_dirs, view)

	prof.stop()
end

return M
