----------------------------------------------------------------------
-- The row cache.
--
-- A snapshot is what one find(1) run produced, kept in a form cheap enough
-- to hold for a whole session: integer arrays plus the raw find output as a
-- single retained string.  Everything a re-projection of an
-- already-scanned tree needs (toggle hidden, re-sort, post-save re-render,
-- fold restore, path resolution) is answered from here instead of from a
-- fresh scan or a re-parse of the buffer.
--
-- Why this shape.  At 100k+ entries the thing that makes Neovim feel laggy
-- is not resident memory, it is GC traversal.  In LuaJIT an array of
-- numbers is one GC object and holds no references, so the collector skips
-- straight over it; an array of 100k strings is 100k objects to trace, and
-- a path→lnum hash is worse.  So the rule here is:
--
--     integer arrays and one big string; never an array of strings.
--
-- Names are (offset, length) slices into `raw` and are materialized only
-- when someone asks.  Line text is not cached at all -- Neovim already
-- holds it, outside the Lua heap.  Paths are rebuilt from the `parent`
-- chain on demand (O(depth)) and thrown away.
--
-- Rows are numbered 1..n in find(1) emission order and never renumbered.
-- Display order lives in `order` (a permutation) and the visible
-- projection in `view` / `row_of`, so re-sorting or re-filtering never
-- touches the row data itself.
----------------------------------------------------------------------
local M = {}

----------------------------------------------------------------------
-- Row kind / flags, packed into one integer per row
----------------------------------------------------------------------

M.KIND_FILE = 0
M.KIND_DIR = 1
M.KIND_LINK = 2

local KIND_MASK = 3

M.F_HIDDEN = 4 -- basename starts with "."
M.F_IGNORED = 8 -- gitignored
M.F_TRUNCATED = 16 -- directory at maxdepth, children not loaded

local KIND_DIR, KIND_LINK = M.KIND_DIR, M.KIND_LINK
local F_HIDDEN, F_IGNORED, F_TRUNCATED = M.F_HIDDEN, M.F_IGNORED, M.F_TRUNCATED

local TYPE_NAME = { [M.KIND_FILE] = "file", [M.KIND_DIR] = "dir", [M.KIND_LINK] = "link" }

local DOT = 46 -- string.byte(".")

--- Exact-size array allocation.
---
--- LuaJIT rounds a table's array part up to a power of two as it grows by
--- append, so an array reaching 313k slots occupies 524288 of them -- 4.00MB
--- where 2.39MB would do.  With eight row-indexed arrays that rounding was
--- the single largest contributor to the cache's footprint.  table.new sizes
--- the array part exactly, which is why M.build counts rows before filling
--- anything.
local ok_tnew, tnew = pcall(require, "table.new")
local function newarr(n, hash)
	if ok_tnew then
		return tnew(n, hash or 0)
	end
	return {}
end

----------------------------------------------------------------------
-- Construction
----------------------------------------------------------------------

--- An empty snapshot for `root`.
---@param root string  absolute, no trailing slash
---@return table
function M.new(root)
	return {
		root = root,
		raw = "",
		n = 0,
		pruned = false, -- raw lacks gitignored subtrees (find -prune)
		off = {},
		len = {},
		indent = {},
		kind = {}, -- kind bits | flag bits
		parent = {}, -- row index of parent dir, 0 = child of root
		-- Child index in CSR form: the children of row p are
		-- child_flat[child_start[p] .. child_start[p + 1] - 1].  Two flat
		-- integer arrays rather than a table per directory -- at 313k rows
		-- that was ~32k table headers plus power-of-two slack, ~9MB of pure
		-- overhead.
		child_start = nil, -- (n + 2) ints, indexed 0..n+1
		child_flat = nil, -- n ints, child rows grouped by parent
		sorted = nil, -- parent row → true, its range ordered under sorted_by
		view = nil, -- visible projection: view[lnum] = row
		row_of = nil, -- inverse: row_of[row] = lnum
		show_hidden = nil, -- which projection `view` currently holds
		sorted_by = nil, -- which method `order` currently holds
	}
end

--- Parse find(1) output into row arrays.
---
--- The output is retained verbatim as `snap.raw` and names are recorded as
--- slices into it, so this loop allocates no string per row: the depth
--- field is read with one small sub, the type is a single byte, and the
--- name is never materialized unless the ignore check below needs it.
--- The previous version built an absolute path string for every entry --
--- including entries it was about to discard -- which was the single
--- largest allocation in the scan.
---
--- `ignore_set` is keyed by absolute path, but `git ls-files --directory`
--- collapses fully-ignored directories, so the set is small.  A basename
--- index over it acts as a cheap superset filter: a row whose name is not
--- in the index cannot be ignored, so the O(depth) path build runs only for
--- the handful of rows that could actually match.
---
---@param snap       table    from M.new
---@param output     string   raw find stdout, "depth\ttype\tname\n" per row
---@param maxdepth   number
---@param ignore_set table|nil  absolute ignored paths → true
---@param pruned     boolean  whether find already pruned ignored dirs
function M.build(snap, output, maxdepth, ignore_set, pruned)
	snap.raw = output
	snap.pruned = pruned and true or false
	snap.view, snap.row_of, snap.sorted = nil, nil, nil
	snap.child_start, snap.child_flat = nil, nil
	snap.sorted_by, snap.show_hidden = nil, nil

	-- Exact row count first, so every array below is allocated at its final
	-- size (see newarr).  One memchr pass over the output -- ~2ms at 6MB,
	-- against ~1.6MB saved per row array.
	local nrows = 0
	do
		local at = 1
		while true do
			local e = output:find("\n", at, true)
			if not e then
				break
			end
			nrows = nrows + 1
			at = e + 1
		end
	end

	local off, len, indent, kind, parent =
		newarr(nrows), newarr(nrows), newarr(nrows), newarr(nrows), newarr(nrows)
	snap.off, snap.len, snap.indent, snap.kind, snap.parent = off, len, indent, kind, parent

	-- Basename index over the ignore set (see above).
	local ignore_names = nil
	if ignore_set then
		for path in pairs(ignore_set) do
			local slash = path:match(".*()/")
			local base = slash and path:sub(slash + 1) or path
			ignore_names = ignore_names or {}
			ignore_names[base] = true
		end
	end

	-- stack[d] = row index of the directory at depth d on the current path.
	local stack = {}
	local n = 0
	local pos = 1
	local total = #output

	while pos <= total do
		-- depth \t type \t name \n, located without capturing.
		local t1 = output:find("\t", pos, true)
		if not t1 then
			break
		end
		local t2 = output:find("\t", t1 + 1, true)
		if not t2 then
			break
		end
		local eol = output:find("\n", t2 + 1, true) or (total + 1)

		local depth = tonumber(output:sub(pos, t1 - 1))
		if depth then
			local ftype = output:byte(t1 + 1)
			local is_dir = ftype == 100 -- "d"
			local name_off = t2 + 1
			local name_len = eol - name_off

			n = n + 1
			off[n] = name_off
			len[n] = name_len
			indent[n] = depth - 1
			parent[n] = stack[depth - 1] or 0

			local bits = is_dir and KIND_DIR or (ftype == 108 and KIND_LINK or 0) -- "l"
			if output:byte(name_off) == DOT then
				bits = bits + F_HIDDEN
			end
			if ignore_names then
				local name = output:sub(name_off, eol - 1)
				if ignore_names[name] then
					-- Only now is a path worth building.  off/len/parent for
					-- this row are already set, and every ancestor is complete.
					if ignore_set[M.path_of(snap, n, name)] then
						bits = bits + F_IGNORED
					end
				end
			end
			if is_dir then
				if depth >= maxdepth then
					bits = bits + F_TRUNCATED
				end
				-- No need to clear deeper stack slots: find(1) is depth-first,
				-- so a row at depth d is always preceded by its own ancestor at
				-- depth d-1, and stack[d-1] is overwritten before it is read.
				stack[depth] = n
			end
			kind[n] = bits
		end

		pos = eol + 1
	end

	snap.n = n
	return snap
end

----------------------------------------------------------------------
-- Row accessors
----------------------------------------------------------------------

--- Basename of `row`.
---@param snap table
---@param row  number
---@return string
function M.name(snap, row)
	local o = snap.off[row]
	return snap.raw:sub(o, o + snap.len[row] - 1)
end

--- "dir" | "link" | "file"
---@param snap table
---@param row  number
---@return string
function M.type(snap, row)
	return TYPE_NAME[snap.kind[row] % (KIND_MASK + 1)] or "file"
end

---@param snap table
---@param row  number
---@return boolean
function M.is_dir(snap, row)
	return snap.kind[row] % (KIND_MASK + 1) == KIND_DIR
end

--- Test a flag bit (M.F_HIDDEN / F_IGNORED / F_TRUNCATED).
---@param snap table
---@param row  number
---@param flag number
---@return boolean
function M.has_flag(snap, row, flag)
	return math.floor(snap.kind[row] / flag) % 2 == 1
end

--- Absolute path of `row`, rebuilt from the parent chain.  O(depth), and
--- the result is deliberately not cached -- a path→row map over the whole
--- tree is the one structure this module exists to avoid.
---@param snap  table
---@param row   number
---@param name? string  the row's own name, when the caller already has it
---@return string
function M.path_of(snap, row, name)
	local raw, off, len, parent = snap.raw, snap.off, snap.len, snap.parent
	local segs = { name or raw:sub(off[row], off[row] + len[row] - 1) }
	local p = parent[row]
	local k = 1
	while p and p > 0 do
		k = k + 1
		segs[k] = raw:sub(off[p], off[p] + len[p] - 1)
		p = parent[p]
	end
	-- segs is deepest-first; reverse into a root-first path.
	local parts = { snap.root }
	for i = k, 1, -1 do
		parts[#parts + 1] = segs[i]
	end
	return table.concat(parts, "/")
end

----------------------------------------------------------------------
-- Display order
----------------------------------------------------------------------

--- Build the CSR child index: counting sort of rows by parent.
--- Also the structure that resolves a path to a row without a path map.
---@param snap table
function M.build_index(snap)
	local n, parent = snap.n, snap.parent

	-- 1. Count children per parent, offset by one so the counts can be
	--    turned into start offsets in place.  Index 0 lands in the hash part
	--    (LuaJIT's array part is 1-based), hence the hash slot.
	local start = newarr(n + 2, 1)
	for p = 0, n + 1 do
		start[p] = 0
	end
	for row = 1, n do
		local p = parent[row] + 1
		start[p] = start[p] + 1
	end

	-- 2. Prefix sum → start[p] is where p's children begin.  Because the
	--    counts sit one slot high, accumulating before the store turns
	--    start[p] into "end of p-1" == "start of p" in a single pass.
	local acc = 1
	for p = 0, n + 1 do
		acc = acc + start[p]
		start[p] = acc
	end

	-- 3. Scatter rows into their parent's range, preserving emission order.
	local flat = newarr(n)
	local cursor = {}
	for row = 1, n do
		local p = parent[row]
		local at = cursor[p] or start[p]
		flat[at] = row
		cursor[p] = at + 1
	end

	snap.child_start = start
	snap.child_flat = flat
	return start, flat
end

local PRIO = { [KIND_DIR] = 1, [KIND_LINK] = 2, [0] = 3 }

--- Order one sibling range of `child_flat` in place.
---
--- table.sort cannot sort a slice, so the range is lifted into a temporary,
--- sorted, and written back.  The temporary is transient garbage; what
--- matters for this module is that nothing per-row is *retained*.  Keys are
--- likewise built per range and dropped -- a persistent lowercased-name
--- array over every row would be exactly the 100k-string structure the
--- module exists to avoid -- while still costing one name:lower() per row
--- rather than one per comparison.
---@param snap   table
---@param s      number  first index in child_flat
---@param e      number  one past the last index
---@param method string
local function sort_range(snap, s, e, method)
	local k = e - s
	if k < 2 then
		return
	end
	local raw, off, len, kind, flat = snap.raw, snap.off, snap.len, snap.kind, snap.child_flat

	local rows, key = {}, {}
	if method == "name" then
		for i = 1, k do
			local r = flat[s + i - 1]
			rows[i] = r
			key[r] = raw:sub(off[r], off[r] + len[r] - 1):lower()
		end
	else
		-- Type priority is a single leading digit, so a plain string compare
		-- orders by type first and name second.
		for i = 1, k do
			local r = flat[s + i - 1]
			rows[i] = r
			key[r] = (PRIO[kind[r] % (KIND_MASK + 1)] or 5) .. raw:sub(off[r], off[r] + len[r] - 1):lower()
		end
	end

	table.sort(rows, function(a, b)
		return key[a] < key[b]
	end)

	for i = 1, k do
		flat[s + i - 1] = rows[i]
	end
end

----------------------------------------------------------------------
-- Visible projection
----------------------------------------------------------------------

--- Compute `view` / `row_of`: which rows are displayed, in display order.
---
--- Ordering and filtering are one DFS, not two passes, because that lets a
--- sibling bucket be sorted the first time the walk actually descends into
--- it.  A directory hidden by the current projection is never descended,
--- so its subtree is never sorted -- which matters a lot: the snapshot
--- holds every row on disk so toggling is cheap, but a hidden node_modules
--- can easily be most of them, and sorting all of it up front made a cold
--- open slower than the pipeline this replaces.
---
--- Buckets remember that they are sorted, so flipping the projection only
--- pays for the buckets it newly reaches, and flipping back pays nothing.
---@param snap        table
---@param method      string|nil   "type" | "name" | other = emission order
---@param show_hidden boolean
---@return table view    view[lnum] = row
---@return table row_of  row_of[row] = lnum
function M.project(snap, method, show_hidden)
	if not snap.child_start then
		M.build_index(snap)
	end
	local start, flat, kind = snap.child_start, snap.child_flat, snap.kind

	-- A different sort method invalidates every recorded range order.
	if snap.sorted_by ~= method then
		snap.sorted = {}
		snap.sorted_by = method
	end
	local sorted = snap.sorted
	local orderable = (method == "name" or method == "type")

	-- row_of is indexed by row so it gets the exact size; view's final length
	-- is not known until the walk finishes, so it grows.
	local view, row_of = {}, newarr(snap.n)
	local lnum = 0

	--- Range of p's children, ordered on first visit.
	local function ordered(p)
		local s, e = start[p], start[p + 1]
		if e > s and not sorted[p] then
			if orderable then
				sort_range(snap, s, e, method)
			end
			sorted[p] = true
		end
		return s, e
	end

	-- DFS over CSR ranges: frame_pos is the cursor into child_flat, frame_end
	-- one past the frame's last child.
	local frame_pos, frame_end = {}, {}
	frame_pos[1], frame_end[1] = ordered(0)
	local depth = 1
	while depth > 0 do
		local pos = frame_pos[depth]
		if pos >= frame_end[depth] then
			depth = depth - 1
		else
			frame_pos[depth] = pos + 1
			local row = flat[pos]
			local bits = kind[row]
			local dimmed = not show_hidden
				and (math.floor(bits / F_HIDDEN) % 2 == 1 or math.floor(bits / F_IGNORED) % 2 == 1)
			if not dimmed then
				lnum = lnum + 1
				view[lnum] = row
				row_of[row] = lnum
				-- Descend only into what is on screen; that is what keeps the
				-- hidden half of the tree unsorted.
				if bits % (KIND_MASK + 1) == KIND_DIR then
					local s, e = ordered(row)
					if e > s then
						depth = depth + 1
						frame_pos[depth], frame_end[depth] = s, e
					end
				end
			end
		end
	end

	snap.view = view
	snap.row_of = row_of
	snap.show_hidden = show_hidden
	return view, row_of
end

----------------------------------------------------------------------
-- Buffer lines
----------------------------------------------------------------------

local ESCAPE = { ["\n"] = "$'\\n'", ["\r"] = "$'\\r'", ["\t"] = "$'\\t'" }

--- Render the visible rows to buffer text.
---
--- The only stage that allocates a string per row, and it only ever runs
--- over `view`.  Indent prefixes are memoized and the indent settings read
--- once, matching line.formatter (which this replaces on the snapshot path).
---@param snap table
---@return string[] lines
function M.lines(snap)
	local view = snap.view or select(1, M.project(snap, snap.sorted_by, snap.show_hidden or false))
	local raw, off, len, kind = snap.raw, snap.off, snap.len, snap.kind
	local indent = snap.indent

	local use_tabs = not vim.go.expandtab
	local sw = vim.go.shiftwidth
	local width = (sw > 0 and sw) or vim.go.tabstop
	local unit = use_tabs and "\t" or string.rep(" ", width)
	local prefixes = { [0] = "" }

	local lines = {}
	for lnum = 1, #view do
		local row = view[lnum]
		local level = indent[row]
		local prefix = prefixes[level]
		if not prefix then
			prefix = string.rep(unit, level)
			prefixes[level] = prefix
		end
		local name = raw:sub(off[row], off[row] + len[row] - 1)
		if name:find("[\n\r\t]") then
			name = name:gsub("[\n\r\t]", ESCAPE)
		end
		local k = kind[row] % (KIND_MASK + 1)
		if k == KIND_DIR then
			lines[lnum] = prefix .. name .. "/"
		elseif k == KIND_LINK then
			lines[lnum] = prefix .. name .. "@"
		else
			lines[lnum] = prefix .. name
		end
	end
	return lines
end

----------------------------------------------------------------------
-- Lookups
----------------------------------------------------------------------

--- Entry table for a displayed line, in the shape state.resolve_entry
--- returns so callers need no branch.
---@param snap table
---@param lnum number  1-based buffer line
---@return table|nil
function M.entry(snap, lnum)
	local view = snap.view
	if not view then
		return nil
	end
	local row = view[lnum]
	if not row then
		return nil
	end
	local name = M.name(snap, row)
	return {
		lnum = lnum,
		row = row,
		path = M.path_of(snap, row, name),
		name = name,
		type = M.type(snap, row),
		indent = snap.indent[row],
		is_hidden = M.has_flag(snap, row, F_HIDDEN) or nil,
		lazy = (M.is_dir(snap, row) and M.has_flag(snap, row, F_TRUNCATED)) or nil,
	}
end

--- Resolve an absolute path to a row by descending the children index one
--- segment at a time -- O(depth * siblings) with no path map anywhere.
---@param snap table
---@param path string
---@return number|nil row
function M.row_of_path(snap, path)
	local root = snap.root
	if path == root then
		return nil
	end
	if path:sub(1, #root + 1) ~= root .. "/" then
		return nil
	end
	if not snap.child_start then
		M.build_index(snap)
	end
	local start, flat = snap.child_start, snap.child_flat
	local raw, off, len = snap.raw, snap.off, snap.len

	local row = 0
	for seg in path:sub(#root + 2):gmatch("[^/]+") do
		local found = nil
		local seglen = #seg
		for i = start[row], start[row + 1] - 1 do
			local c = flat[i]
			if len[c] == seglen and raw:sub(off[c], off[c] + seglen - 1) == seg then
				found = c
				break
			end
		end
		if not found then
			return nil
		end
		row = found
	end
	return row > 0 and row or nil
end

--- Buffer line currently showing `path`, or nil when it isn't displayed.
---@param snap table
---@param path string
---@return number|nil
function M.lnum_of_path(snap, path)
	local row = M.row_of_path(snap, path)
	if not row or not snap.row_of then
		return nil
	end
	return snap.row_of[row]
end

--- Paths of the directories flagged truncated (at maxdepth), as a set.
--- Small by construction -- only the deepest directory layer qualifies.
---@param snap table
---@return table  path → true
function M.truncated_paths(snap)
	local out = {}
	for row = 1, snap.n do
		local bits = snap.kind[row]
		if bits % (KIND_MASK + 1) == KIND_DIR and math.floor(bits / F_TRUNCATED) % 2 == 1 then
			out[M.path_of(snap, row)] = true
		end
	end
	return out
end

--- Approximate Lua-heap footprint, for profiling.  Counts array slots and
--- the retained output; excludes the interned name strings, which are
--- shared with the buffer text.
---@param snap table
---@return number bytes
function M.footprint(snap)
	local slots = snap.n * 5 -- off, len, indent, kind, parent
	if snap.view then
		slots = slots + #snap.view + snap.n -- view + row_of
	end
	if snap.child_start then
		slots = slots + snap.n * 2 + 2 -- child_start + child_flat
	end
	return slots * 8 + #snap.raw
end

return M
