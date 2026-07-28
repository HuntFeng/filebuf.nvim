----------------------------------------------------------------------
-- Per-buffer state.
--
-- The buffer text is the source of truth for the tree: names, types and
-- structure all live in the lines themselves (see filebuf.line).  The only
-- thing a line does not carry is its absolute path, because that needs the
-- ancestry above it — so that, and nothing else, is indexed here.
--
-- The index is three parallel arrays (paths / types / indents) plus two sparse
-- flag sets, all 1:1 with buffer lines.  Parallel arrays rather than a list of
-- entry tables: building 100k tables per render costs real time and GC
-- pressure, while filling three arrays is nearly free.  Entry tables are
-- materialized one at a time, on demand, by M.entry().
--
-- State lives in a module-local table, never in vim.b.  vim.b hands out a deep
-- copy on every read and re-serializes on every write, which cost ~257ms per
-- open on a 100k-entry tree and bought nothing — plus the copies meant the same
-- logical entry existed as several unrelated tables, so a flag cleared on one
-- stayed stale on the others.
--
-- After an edit the index is stale only *below* the edit: on_lines lowers the
-- `valid` watermark to the first changed line, and lookups past it re-derive
-- the path by walking back to the nearest still-valid line.  Since edits happen
-- where the cursor is, that walk is normally a handful of lines.
----------------------------------------------------------------------
local line_mod = require("filebuf.line")

local M = {}

--- bufnr -> state.  Module-local on purpose; see the header.
local states = {}

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

--- Create (or reset) the state for `buf`.
---@param buf  number
---@param root string  absolute root directory, no trailing slash
---@return table state
function M.init(buf, root)
	states[buf] = {
		root = root,

		-- Index: 1:1 with buffer lines, trustworthy for lines 1..valid.
		paths = {}, -- lnum -> absolute path
		names = {}, -- lnum -> basename
		types = {}, -- lnum -> "dir" | "link" | "file"
		indents = {}, -- lnum -> depth level
		hidden = {}, -- lnum -> true  (sparse)
		ignored = {}, -- lnum -> true  (sparse)
		count = 0, -- number of indexed lines
		valid = 0, -- paths[1..valid] are current

		--- Directories whose children are rendered.  In lazy mode this is what
		--- the user opened; in eager mode only the dirs that turned out to be
		--- empty are recorded, since "has children below it" is otherwise read
		--- straight off the index (see is_lazy).
		expanded = {},

		eager = false, -- whole-tree scan on render
		truncated = false, -- eager scan stopped at eager_max_entries
		mode = "normal", -- "normal" | "find"
		git = nil, -- path -> git status
		matches = nil, -- path -> true  (search highlighting)
		rendering = false, -- suppress on_lines bookkeeping mid-render
		attached = false,
	}
	return states[buf]
end

---@param buf number
---@return table|nil
function M.get(buf)
	return states[buf]
end

--- Root directory of `buf`, or nil when it isn't a filebuf.
---@param buf number
---@return string|nil
function M.root(buf)
	local st = states[buf]
	return st and st.root
end

--- Whether `buf` is a live filebuf buffer.
---@param buf number
---@return boolean
function M.is_filebuf(buf)
	return states[buf] ~= nil
end

--- Drop all state for `buf`.
---@param buf number
function M.clear(buf)
	states[buf] = nil
end

--- Every live filebuf buffer number.
---@return number[]
function M.buffers()
	local out = {}
	for buf in pairs(states) do
		out[#out + 1] = buf
	end
	return out
end

----------------------------------------------------------------------
-- Index maintenance
----------------------------------------------------------------------

--- Install a freshly-rendered index.  Called by filebuf.render only.
---@param buf   number
---@param index table  { paths, types, indents, hidden, ignored, count }
function M.set_index(buf, index)
	local st = states[buf]
	if not st then
		return
	end
	st.paths = index.paths
	st.names = index.names
	st.types = index.types
	st.indents = index.indents
	st.hidden = index.hidden
	st.ignored = index.ignored
	st.count = index.count
	st.valid = index.count
	st._by_path = nil
end

--- Mark the index stale from (1-based) `lnum` onward.
---@param buf  number
---@param lnum number
function M.invalidate(buf, lnum)
	local st = states[buf]
	if not st then
		return
	end
	local upto = lnum - 1
	if upto < st.valid then
		st.valid = upto < 0 and 0 or upto
	end
	st._by_path = nil
end

--- Watch `buf` for edits so the index knows how far it can still be trusted.
--- Lines above an edit are untouched, so only the watermark moves.
---@param buf number
function M.attach(buf)
	local st = states[buf]
	if not st or st.attached then
		return
	end
	st.attached = true
	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function(_, b, _, firstline)
			local s = states[b]
			if not s then
				return true -- detach
			end
			if s.rendering then
				return false
			end
			-- firstline is 0-based, so buffer lines 1..firstline are unchanged.
			if firstline < s.valid then
				s.valid = firstline
			end
			s._by_path = nil
			return false
		end,
		on_detach = function(_, b)
			local s = states[b]
			if s then
				s.attached = false
			end
		end,
	})
end

----------------------------------------------------------------------
-- Entry materialization
----------------------------------------------------------------------

--- A directory is "lazy" (unexpanded) when nothing below it is deeper than it
--- and it isn't a known-empty expanded dir.  Derived from the index rather than
--- tracked, so it can never go stale.
local function is_lazy(st, lnum, path, type_)
	if type_ ~= "dir" then
		return nil
	end
	if st.expanded[path] then
		return nil
	end
	local below = st.indents[lnum + 1]
	if below and below > st.indents[lnum] then
		return nil
	end
	return true
end

--- Build an entry table from indexed data.
---
--- The name comes out of the index rather than being recovered from the path.
--- `path:match("[^/]+$")` looks like the obvious way to do it and is a trap:
--- Lua patterns scan left to right, so an end-anchored character class
--- backtracks across the whole string — 1.5s for 89k paths averaging 150
--- characters. The scan already knows every name, so it just carries them.
local function build(st, lnum, path, type_, indent)
	return {
		lnum = lnum,
		path = path,
		type = type_,
		indent = indent,
		name = st.names[lnum] or path:match("^.*/(.*)$") or path,
		is_hidden = st.hidden[lnum] or nil,
		is_ignored = st.ignored[lnum] or nil,
		lazy = is_lazy(st, lnum, path, type_),
	}
end

--- Read one buffer line's name and indent without touching the index.
local function read_line(buf, lnum)
	local text = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
	if not text then
		return nil
	end
	local name, is_dir, is_link = line_mod.parse_line(text)
	if name == "" then
		return nil
	end
	return name, line_mod.indent_level(text), (is_dir and "dir" or (is_link and "link" or "file"))
end

--- Absolute path of the parent chain for a line at `indent`, by walking back to
--- the nearest line the index still vouches for.
local function ancestor_path(st, buf, lnum, indent)
	if indent <= 0 then
		return st.root
	end
	local want = indent - 1
	local segs = {} -- collected deepest-first
	local i = lnum - 1
	while want >= 0 and i >= 1 do
		local ind, known, name
		if i <= st.valid and st.indents[i] then
			ind, known = st.indents[i], st.paths[i]
		else
			local nm, nind = read_line(buf, i)
			if nm then
				name, ind = nm, nind
			end
		end
		if ind and ind == want then
			if known then
				-- Known ancestor: everything above it is already in its path.
				local base = known
				for k = #segs, 1, -1 do
					base = base .. "/" .. segs[k]
				end
				return base
			end
			if name then
				segs[#segs + 1] = name
				want = want - 1
			end
		end
		i = i - 1
	end
	local base = st.root
	for k = #segs, 1, -1 do
		base = base .. "/" .. segs[k]
	end
	return base
end

--- The entry on line `lnum`, or nil.  O(1) while the index is current; past the
--- edit watermark it costs one short backward walk.
---@param buf  number
---@param lnum number  1-based
---@return table|nil
function M.entry(buf, lnum)
	local st = states[buf]
	if not st or not lnum or lnum < 1 then
		return nil
	end
	if lnum <= st.valid then
		local path = st.paths[lnum]
		if not path then
			return nil
		end
		return build(st, lnum, path, st.types[lnum], st.indents[lnum])
	end

	local name, indent, type_ = read_line(buf, lnum)
	if not name then
		return nil
	end
	local path = ancestor_path(st, buf, lnum, indent) .. "/" .. name
	return {
		lnum = lnum,
		path = path,
		type = type_,
		indent = indent,
		name = name,
		is_hidden = (name:sub(1, 1) == ".") or nil,
		is_ignored = nil,
		lazy = type_ == "dir" and not st.expanded[path] or nil,
	}
end

--- The entry under the cursor in the current window, or nil.
---@param buf number
---@return table|nil
function M.entry_at_cursor(buf)
	return M.entry(buf, vim.api.nvim_win_get_cursor(0)[1])
end

--- Every entry in the buffer, in line order.
---
--- Cheap when the index is current (materialize from the arrays); after edits
--- it falls back to a full re-parse of the text, re-attaching the flags the
--- text cannot carry.  Whole-buffer work — keep it off per-redraw paths.
---@param buf number
---@return table[]
function M.entries(buf)
	local st = states[buf]
	if not st then
		return {}
	end
	local total = vim.api.nvim_buf_line_count(buf)

	if st.valid >= total and st.count == total then
		local out = {}
		for lnum = 1, total do
			local path = st.paths[lnum]
			if path then
				out[#out + 1] = build(st, lnum, path, st.types[lnum], st.indents[lnum])
			end
		end
		return out
	end

	local entries = require("filebuf.buffer").parse_buffer(buf, st.root)
	-- is_hidden / is_ignored aren't in the text; recover them by path from the
	-- last render.  Dot-prefixed names are re-derived directly.
	local hidden, ignored = {}, {}
	for lnum = 1, st.count do
		local path = st.paths[lnum]
		if path then
			if st.hidden[lnum] then
				hidden[path] = true
			end
			if st.ignored[lnum] then
				ignored[path] = true
			end
		end
	end
	for _, e in ipairs(entries) do
		if hidden[e.path] or e.name:sub(1, 1) == "." then
			e.is_hidden = true
		end
		if ignored[e.path] then
			e.is_ignored = true
		end
		if e.type == "dir" and not st.expanded[e.path] then
			e.lazy = true
		end
	end
	return entries
end

----------------------------------------------------------------------
-- Path lookup
----------------------------------------------------------------------

--- Line number of `path`, or nil.  The path→lnum map is built on first use and
--- dropped whenever the index changes, so repeated lookups (reveal, search,
--- cursor restore) are O(1) instead of a linear scan each.
---@param buf  number
---@param path string
---@return number|nil
function M.lnum_of(buf, path)
	local st = states[buf]
	if not st then
		return nil
	end
	if not st._by_path then
		local map = {}
		for lnum = 1, st.count do
			local p = st.paths[lnum]
			if p then
				map[p] = lnum
			end
		end
		st._by_path = map
	end
	return st._by_path[path]
end

--- The entry for `path`, or nil when it isn't currently displayed.
---@param buf  number
---@param path string
---@return table|nil
function M.entry_of(buf, path)
	local lnum = M.lnum_of(buf, path)
	return lnum and M.entry(buf, lnum) or nil
end

--- Set of directory paths whose fold is currently open.
---@param buf number
---@return table  path -> true
function M.open_dirs(buf)
	local st = states[buf]
	local open = {}
	if not st then
		return open
	end
	for lnum = 1, st.count do
		if st.types[lnum] == "dir" and vim.fn.foldclosed(lnum) == -1 then
			open[st.paths[lnum]] = true
		end
	end
	return open
end

return M
