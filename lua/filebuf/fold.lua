----------------------------------------------------------------------
-- Fold state, path reveal and winbar.
--
-- Folds are not built here: 'foldexpr' (FilebufFoldExpr below) derives
-- every fold range from a line's indentation and its trailing "/", so
-- Neovim maintains them itself and recomputes only what a buffer change
-- touched.  What is left is open/closed state, which the plugin persists
-- per root in M.open_folds.
--
-- Fold state is captured lazily — only before re-renders (which destroy
-- native fold state) and on buffer close.  Between re-renders, Neovim
-- handles fold state natively, and users can use any keymaps they want
-- for zo, zc, za, zO, zR, zM without plugin intervention.
--
-- The capture_fold_state / restore_folds pair bridges the gap: capture
-- reads live fold state from the buffer, and restore replays it after
-- the buffer text is rewritten.
--
-- The module also loads the ancestor chain of a target path so it becomes
-- a visible line (reveal_path / reveal_paths, which search and find mode
-- use to surface hits), and drives the winbar.
----------------------------------------------------------------------
local state = require("filebuf.state")
local git = require("filebuf.git")

local M = {}

--- Persisted fold state, keyed by root directory.  Each value is the set of
--- directory paths whose fold is open; survives buffer close/reopen so the
--- user's fold preferences stick.
---
--- Open rather than closed, because "all closed" is the baseline a render
--- starts from (`zM`): an empty set is the default, so nothing ever has to
--- enumerate every directory in the tree just to say "untouched".
M.open_folds = {}

--- The open-fold set for `root`, created on first use.
---@param root string
---@return table  path → true
function M.open_set(root)
	local set = M.open_folds[root]
	if not set then
		set = {}
		M.open_folds[root] = set
	end
	return set
end

--- Capture the current native fold state into M.open_folds for `buf`'s root.
---
--- Walks the buffer once, checking foldclosed() on every directory.
--- Called before re-renders (which destroy native fold state) and on buffer
--- close so that reopen at the same root remembers the user's fold preferences.
---
--- No call is needed on every fold keystroke — Neovim handles native fold
--- state between re-renders; this only bridges the gap across buffer rewrites.
---@param buf number
function M.capture_fold_state(buf)
	local root = state.root(buf)
	if not root then
		return
	end

	-- Don't capture from a buffer that hasn't been rendered yet (no snapshot
	-- or empty snapshot).  A fresh buffer has no folds to read — and capturing
	-- an empty set here would wipe fold state saved from a previous session.
	local st = state.get(buf)
	if not st or not st.snap or st.snap.n == 0 then
		return
	end

	local set = {}
	state.walk(buf, root, function(lnum, path, type_)
		if type_ == "dir" and vim.fn.foldclosed(lnum) == -1 then
			set[path] = true
		end
	end)
	M.open_folds[root] = set
end

----------------------------------------------------------------------
-- Fold computation ('foldexpr')
----------------------------------------------------------------------

--- Cached indent settings for the fold expression.  The expression runs
--- once per buffer line — 100k+ times on a large tree — and reading
--- vim.go there costs more than the rest of the expression put together,
--- so the values are cached and invalidated explicitly (see the OptionSet
--- autocmd registered in filebuf.setup).
local indent_cfg = nil

--- Fold levels as strings, so the once-per-line expression returns an
--- interned constant instead of allocating through tostring.  Levels beyond
--- this fall back to tostring; max_depth defaults to 20.
local LEVEL_STR = {}
for i = 0, 32 do
	LEVEL_STR[i] = tostring(i)
end

--- How one level of indent is spelled in the buffer.  Mirrors
--- line.indent_str / line.indent_level, which drive the rendering side.
---@return table  { tabs: boolean, width: number }
local function fold_indent_cfg()
	if not indent_cfg then
		local sw = vim.go.shiftwidth
		indent_cfg = {
			tabs = not vim.go.expandtab,
			width = (sw > 0 and sw) or vim.go.tabstop,
		}
	end
	return indent_cfg
end

--- Drop the cached indent settings.
function M.invalidate_indent_cache()
	indent_cfg = nil
end

--- Indent depth of a buffer line, plus whether the line holds no entry at
--- all.  Same result as line.indent_level, without its per-call option
--- lookups.
---@param line string
---@param cfg  table
---@return number level
---@return boolean blank
local function fold_level_of(line, cfg)
	local ws = (cfg.tabs and line:match("^\t*") or line:match("^ *")) or ""
	if #ws == #line then
		return 0, true
	end
	if cfg.tabs then
		return #ws, false
	end
	return math.floor(#ws / cfg.width), false
end

--- Fold-level callback (v:lua.FilebufFoldExpr), evaluated once per line.
---
--- A directory owns a fold spanning its descendants: it starts a fold one
--- level deeper than itself, and its children — indented one level more —
--- fall inside it.  A directory with nothing deeper after it starts no
--- fold, so empty and unexpanded folders keep a clean fold column.
---
--- The current and the following line arrive in a single
--- nvim_buf_get_lines call; the following line is what says whether the
--- directory has children.
---@return string
function _G.FilebufFoldExpr()
	local lnum = vim.v.lnum

	-- Snapshot fast path.  This expression is evaluated once per line, so on a
	-- 100k-line tree the version below costs 100k nvim_buf_get_lines calls, a
	-- table allocation each, plus a tostring -- paid again on every re-render,
	-- since writing the lines is what makes Neovim recompute the folds.  Off
	-- the snapshot it is two array reads and no allocation.
	local st = state.get(vim.api.nvim_get_current_buf())
	if st and st.snap_clean and st.snap then
		local snap = st.snap
		local row = snap.view[lnum]
		if not row then
			return "0"
		end
		local level = snap.indent[row]
		if snap.kind[row] % 4 == 1 then -- KIND_DIR
			local next_row = snap.view[lnum + 1]
			if next_row and snap.indent[next_row] > level then
				return ">" .. (level + 1)
			end
		end
		return LEVEL_STR[level] or tostring(level)
	end

	local lines = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum + 1, false)
	local line = lines[1]
	if not line then
		return "0"
	end

	local cfg = fold_indent_cfg()
	local level, blank = fold_level_of(line, cfg)
	if blank then
		-- Keep blank lines (mid-edit, mostly) inside the enclosing fold.
		return "="
	end

	if line:sub(-1) == "/" and lines[2] then
		local next_level, next_blank = fold_level_of(lines[2], cfg)
		if not next_blank and next_level > level then
			return ">" .. (level + 1)
		end
	end
	return LEVEL_STR[level] or tostring(level)
end

----------------------------------------------------------------------
-- Fold state restore
----------------------------------------------------------------------

--- Close every fold, then re-open the directories `open_dirs` selects.
---
--- Nothing here creates folds — 'foldexpr' derives them from the buffer
--- text.  A render only has to reset the open/closed state, and `zM` gives
--- a deterministic all-closed baseline: it also pulls 'foldlevel' back to
--- 0, so folds computed after this point start closed too.
---
--- `open_dirs` is either a set of paths to open or a predicate on the path.
--- Directories are visited in buffer order, so a parent is opened before
--- its children (`:foldopen` acts on the outermost closed fold at a line).
---
--- The pass also *records* the resulting open set in M.open_folds, which is
--- why nothing has to read fold state back afterwards: `zM` put every fold
--- in a known state, and this function is what changes it.
---
--- `entries` skips the buffer scan when the caller already holds the
--- rendered entries in memory (find mode).
---@param buf       number
---@param open_dirs table|fun(path: string): boolean|nil
---@param entries   table[]|nil  rendered entries, each carrying lnum and path
function M.restore_folds(buf, open_dirs, entries)
	vim.cmd("silent! normal! zM")

	local root = state.root(buf)

	if not open_dirs then
		-- Nothing to restore — leave M.open_folds alone so state saved
		-- from a previous session survives (e.g. on fresh buffer open).
		return
	end
	local is_open = type(open_dirs) == "function" and open_dirs or function(path)
		return open_dirs[path]
	end

	-- Nothing to open: zM already left every fold closed.  Worth checking,
	-- because after the first render open_folds[root] is an empty-but-truthy
	-- table, and without this the walk below runs over the whole tree to
	-- discover it has no work to do.
	if type(open_dirs) == "table" and next(open_dirs) == nil then
		return
	end

	-- Post-zM every fold is closed; anything opened below is added back.
	local recorded = {}
	if root then
		M.open_folds[root] = recorded
	end

	local function open_dir(lnum, path)
		if is_open(path) then
			vim.cmd(string.format("silent! %dfoldopen", lnum))
			recorded[path] = true
		end
	end

	if entries then
		for _, e in ipairs(entries) do
			if e.type == "dir" then
				open_dir(e.lnum, e.path)
			end
		end
		return
	end

	local st = state.get(buf)
	if root and st and st.snap_clean and st.snap and type(open_dirs) == "table" then
		-- Resolve the wanted paths to rows once, then scan the projection for
		-- those rows.  Building a path for every directory just to test set
		-- membership costs one string concat per directory on a tree that can
		-- have tens of thousands of them; this pays only for the few that are
		-- actually open.
		local snapshot = require("filebuf.snapshot")
		local snap = st.snap
		local open_rows = {}
		for path in pairs(open_dirs) do
			local row = snapshot.row_of_path(snap, path)
			if row then
				open_rows[row] = path
			end
		end
		local view = snap.view
		for lnum = 1, #view do
			local path = open_rows[view[lnum]]
			if path then
				vim.cmd(string.format("silent! %dfoldopen", lnum))
				recorded[path] = true
			end
		end
		return
	end

	if root then
		state.walk(buf, root, function(lnum, path, type_)
			if type_ == "dir" then
				open_dir(lnum, path)
			end
		end)
	end
end

--- Fold-text callback (v:lua.FilebufFoldText).  Shows the entry name with
--- its indent converted to spaces so it aligns regardless of tabstop.
function _G.FilebufFoldText()
	local line = vim.fn.getline(vim.v.foldstart)
	local indent_ws = line:match("^(%s*)") or ""
	local name = line:match("^%s*(.-)%s*$") or line
	local buf = vim.api.nvim_get_current_buf()
	local entry = state.resolve_entry(buf, vim.v.foldstart)
	local text = string.rep(" ", vim.fn.strdisplaywidth(indent_ws)) .. name
	local hl = "Directory"
	if entry and entry.is_hidden then
		hl = "FilebufHiddenDir"
	end

	-- Append git status so closed folders still show what happened inside.
	local st = state.get(buf)
	local status_map = st and st.git
	if status_map and entry then
		local segments = git.dir_status(entry, status_map)
		if segments then
			local result = { { text, hl }, { " ", nil } }
			for _, seg in ipairs(segments) do
				result[#result + 1] = { seg.char, seg.hl }
			end
			return result
		end
	end

	return { { text, hl } }
end

----------------------------------------------------------------------
-- Reveal (load the ancestor chain of a path)
----------------------------------------------------------------------

--- Open the folds of every ancestor directory of `path`.
local function open_ancestor_folds(buf, st, path)
	local rel = path:sub(#st.root + 2)
	local prefix = st.root
	local open = M.open_set(st.root)
	for component in rel:gmatch("([^/]+)/") do
		prefix = prefix .. "/" .. component
		local lnum = state.lnum_of(buf, prefix)
		if lnum then
			vim.cmd(string.format("silent! %dfoldopen", lnum))
			open[prefix] = true
		end
	end
end

--- Open every ancestor directory of the given paths so each target becomes
--- a visible buffer line.
---@param buf   number
---@param paths string[]
---@return table[]  the entries that resolved
function M.reveal_paths(buf, paths)
	local st = state.get(buf)
	if not st then
		return {}
	end

	-- Find each target and open ancestor folds.
	local found = {}
	for _, path in ipairs(paths) do
		if vim.startswith(path, st.root .. "/") then
			open_ancestor_folds(buf, st, path)
			local entry = state.entry_of(buf, path)
			if entry then
				found[#found + 1] = entry
			end
		end
	end

	return found
end

--- Reveal a single path.  Returns its entry, or nil when the target is
--- outside the root, does not exist, or is filtered out.
---@param buf         number
---@param target_path string  absolute path under the filebuf root
---@return table|nil
function M.reveal_path(buf, target_path)
	if not target_path then
		return nil
	end
	return M.reveal_paths(buf, { target_path })[1]
end

return M
