----------------------------------------------------------------------
-- The one place buffer text is produced.
--
-- Previously four routines each formatted lines, called nvim_buf_set_lines and
-- rebuilt folds (full rebuild, lazy expand, find-mode render, find-mode exit),
-- which is why they drifted apart — find mode lost hidden/link decoration
-- because its entries never carried the flags.  Everything now funnels through
-- M.entries().
--
-- There is no incremental path.  Expanding a directory re-renders the whole
-- buffer, which sounds wasteful and isn't: in lazy mode the rendered tree is
-- only as big as what the user opened, and in eager mode there is nothing left
-- to expand.  In exchange, the splice-and-restamp bookkeeping disappears.
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
-- Disk -> entries
----------------------------------------------------------------------

--- Read the tree as it currently is on disk, scoped to what should be visible:
--- the current show_hidden / respect_ignore filter, and the set of directories
--- that are expanded (everything, in eager mode, up to eager_max_entries).
---
--- This is also the diff baseline for :w — sampling disk at save time is what
--- lets the shadow entry list and its clean/dirty snapshots go away.
---@param buf number
---@return table[] entries
function M.scan(buf)
	local st = state.get(buf)
	if not st then
		return {}
	end
	prof.start("render.scan")

	local eager = st.eager
	local cap = config.eager_max_entries or math.huge
	local truncated = false
	local entries, count

	if eager then
		-- Fast path: one find(1) process instead of thousands of
		-- per-directory fs_scandir calls.  Falls back to walk() on
		-- platforms without GNU find (or perl).
		entries, count, truncated = scan.walk_find(st.root, cap)
		if not entries then
			entries, count = scan.walk(st.root, function(path, emitted)
				if st.expanded[path] then
					return true
				end
				if emitted >= cap then
					truncated = true
					return false
				end
				return true
			end)
		end
	else
		entries, count = scan.walk(st.root, function(path, emitted)
			if st.expanded[path] then
				return true
			end
			return false
		end)
	end

	-- Remember directories that turned out to be empty; otherwise they look
	-- unexpanded forever, since "expanded" is otherwise read off the index.
	for _, e in ipairs(entries) do
		if e.expanded_empty then
			st.expanded[e.path] = true
			e.expanded_empty = nil
		end
	end

	st.truncated = truncated
	prof.stop()
	return entries
end

----------------------------------------------------------------------
-- Entries -> buffer
----------------------------------------------------------------------

--- Render an explicit entry list into the buffer and install the index.
--- Used by the normal tree render, by find mode, and by find-mode exit.
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
	local paths, names, types, indents, hidden, ignored = {}, {}, {}, {}, {}, {}

	for i, e in ipairs(entries) do
		e.lnum = i
		lines[i] = fmt(e)
		paths[i] = e.path
		names[i] = e.name
		types[i] = e.type
		indents[i] = e.indent or 0
		if e.is_hidden then
			hidden[i] = true
		end
		if e.is_ignored then
			ignored[i] = true
		end
	end

	-- The decoration provider bails while this is set: buffer content and folds
	-- are both mid-flight, and the redraw after it clears paints everything.
	st.rendering = true

	buffer.without_undo(buf, function()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	end)
	buffer.clear_undo(buf)

	state.set_index(buf, {
		paths = paths,
		names = names,
		types = types,
		indents = indents,
		hidden = hidden,
		ignored = ignored,
		count = #entries,
	})

	local actions = require("filebuf.actions")
	actions.rebuild_folds(buf, entries, open_dirs)
	-- After folds, so directories revealed by this render default to closed.
	actions.save_fold_state(buf, st.root, entries)

	st.git = nil
	if config.git_status then
		git.get_status_map_async(st.root, buf)
	end

	st.rendering = false
	vim.bo[buf].modified = false

	prof.stop()
end

--- Re-read the tree from disk and render it.
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
	-- Only when there is something on screen to read: on a fresh open the index
	-- is empty and persisting from it would erase the fold state we are about to
	-- restore.
	local open_dirs = opts.open_dirs
	if st.count > 0 then
		if open_dirs == nil then
			open_dirs = state.open_dirs(buf)
		end
		require("filebuf.actions").save_fold_state(buf, st.root)
	end

	-- Search match line numbers mean nothing after a re-render.
	st.matches = nil

	scan.clear_ignore_cache()
	M.entries(buf, M.scan(buf), open_dirs)

	-- Warn once per buffer, not on every re-render.
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
