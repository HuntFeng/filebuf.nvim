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
-- Display order lives in the child index (siblings are reordered there) and
-- the visible projection in `view` / `row_of`, so re-sorting or re-filtering
-- never touches the row data itself.
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
M.F_DEAD = 32 -- removed by an applied save; skipped by every projection

local KIND_DIR, KIND_LINK = M.KIND_DIR, M.KIND_LINK
local F_HIDDEN, F_IGNORED, F_TRUNCATED, F_DEAD = M.F_HIDDEN, M.F_IGNORED, M.F_TRUNCATED, M.F_DEAD

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
		names = nil, -- sparse row → name, for rows a save created or renamed
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
		sorted_by = nil, -- which method the child index is ordered by
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
	snap.view, snap.row_of, snap.sorted, snap.names = nil, nil, nil, nil
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

	local off, len, indent, kind, parent = newarr(nrows), newarr(nrows), newarr(nrows), newarr(nrows), newarr(nrows)
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
---
--- Rows created or renamed by an applied save have names that are not in
--- `raw` (it is the immutable find output), so those live in a sparse
--- override table.  `snap.names` stays nil until a save mutates the rows, so
--- the common path is a plain slice.
---@param snap table
---@param row  number
---@return string
function M.name(snap, row)
	local names = snap.names
	if names then
		local n = names[row]
		if n then
			return n
		end
	end
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
	local raw, off, len, parent, names = snap.raw, snap.off, snap.len, snap.parent, snap.names
	local segs = { name or (names and names[row]) or raw:sub(off[row], off[row] + len[row] - 1) }
	local p = parent[row]
	local k = 1
	while p and p > 0 do
		k = k + 1
		segs[k] = (names and names[p]) or raw:sub(off[p], off[p] + len[p] - 1)
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
	local raw, off, len, kind, flat, names = snap.raw, snap.off, snap.len, snap.kind, snap.child_flat, snap.names

	local rows, key = {}, {}
	if method == "name" then
		for i = 1, k do
			local r = flat[s + i - 1]
			rows[i] = r
			key[r] = ((names and names[r]) or raw:sub(off[r], off[r] + len[r] - 1)):lower()
		end
	else
		-- Type priority is a single leading digit, so a plain string compare
		-- orders by type first and name second.
		for i = 1, k do
			local r = flat[s + i - 1]
			rows[i] = r
			key[r] = (PRIO[kind[r] % (KIND_MASK + 1)] or 5)
				.. ((names and names[r]) or raw:sub(off[r], off[r] + len[r] - 1)):lower()
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
			-- Removed by an applied save: neither shown nor descended into, so
			-- the whole deleted subtree disappears without touching its rows.
			if math.floor(bits / F_DEAD) % 2 == 1 then
				goto continue
			end
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
		::continue::
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
	local raw, off, len, kind, names = snap.raw, snap.off, snap.len, snap.kind, snap.names
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
		local name = (names and names[row]) or raw:sub(off[row], off[row] + len[row] - 1)
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
	local raw, off, len, kind, names = snap.raw, snap.off, snap.len, snap.kind, snap.names

	local row = 0
	for seg in path:sub(#root + 2):gmatch("[^/]+") do
		local found = nil
		local seglen = #seg
		for i = start[row], start[row + 1] - 1 do
			local c = flat[i]
			if math.floor(kind[c] / F_DEAD) % 2 == 0 then
				local nm = names and names[c]
				if nm then
					if nm == seg then
						found = c
						break
					end
				elseif len[c] == seglen and raw:sub(off[c], off[c] + seglen - 1) == seg then
					found = c
					break
				end
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
		if
			bits % (KIND_MASK + 1) == KIND_DIR
			and math.floor(bits / F_TRUNCATED) % 2 == 1
			and math.floor(bits / F_DEAD) % 2 == 0
		then
			out[M.path_of(snap, row)] = true
		end
	end
	return out
end

----------------------------------------------------------------------
-- Post-save mutation
----------------------------------------------------------------------

local function parent_of(path)
	return path:match("^(.*)/") or path
end

local function path_depth(path)
	return select(2, path:gsub("/", "/"))
end

--- Add `delta` to the indent of `row` and everything beneath it.
--- Walks the CSR child index, which still describes the pre-mutation
--- structure -- a move changes only the moved row's parent, never the shape
--- of its own subtree.
---@param snap  table
---@param row   number
---@param delta number
function M.shift_subtree_indent(snap, row, delta)
	local start, flat, indent = snap.child_start, snap.child_flat, snap.indent
	indent[row] = indent[row] + delta
	local stack, top = { row }, 1
	while top > 0 do
		local r = stack[top]
		top = top - 1
		for i = start[r], start[r + 1] - 1 do
			local c = flat[i]
			indent[c] = indent[c] + delta
			top = top + 1
			stack[top] = c
		end
	end
end

--- Replay the filesystem ops of a completed save onto the cached rows, so the
--- snapshot describes the new tree without another find(1).
---
--- Safe to do here and nowhere else: these ops have just been applied
--- successfully, so the result is known rather than guessed.
---
--- Descendant paths need no fixing -- a path is built from the parent chain,
--- so renaming a directory re-points its entire subtree for free.  Deletes
--- only flag the top row: `project` neither emits nor descends into a dead
--- row, which removes the subtree with it.
---
--- Returns false when the ops cannot be replayed exactly.  Two of the checks
--- can only be made part-way through, so on false the rows may be partially
--- mutated: **the caller must follow a false return with a full rescan**,
--- which is what rebuilds every array (see M.build).  Every derived structure
--- is dropped before returning so a stale projection cannot be used by
--- accident.  The declined cases are nested cross-parent moves (the same
--- subtree would be indent-shifted twice), a create landing under a directory
--- that is itself being moved, and any op whose path cannot be resolved.
---
--- Note the ignore flags for new and renamed rows are computed from the
--- ignore set of the last scan, since re-reading it means another `git
--- ls-files`.  A path that becomes gitignored as a result of the save shows
--- undimmed until the next :FilebufRefresh or FocusGained.
---
---@param snap       table
---@param ops        table       result of compute_diff, already applied
---@param ignore_set table|nil   absolute ignored paths → true
---@return boolean applied
function M.apply_ops(snap, ops, ignore_set)
	if not snap.child_start then
		M.build_index(snap)
	end
	local kind, indent, parent = snap.kind, snap.indent, snap.parent

	--- Give up, leaving nothing derived behind for a caller to misuse.
	local function abort()
		snap.view, snap.row_of, snap.sorted = nil, nil, nil
		return false
	end

	-- Nested cross-parent moves would shift the same rows twice.
	local moves = {}
	for _, r in ipairs(ops.renamed) do
		if parent_of(r.old.path) ~= parent_of(r.new.path) then
			moves[#moves + 1] = r
		end
	end
	for i = 1, #moves do
		for j = 1, #moves do
			if i ~= j then
				local outer = moves[j].old.path .. "/"
				if moves[i].old.path:sub(1, #outer) == outer then
					return abort()
				end
			end
		end
	end

	-- Every op is addressed by its pre-save path, so resolve them all up front,
	-- before any mutation can invalidate a lookup.  Bailing here leaves the
	-- snapshot untouched.
	local del_rows = {}
	for _, d in ipairs(ops.deleted) do
		local row = M.row_of_path(snap, d.path)
		if not row then
			return abort()
		end
		del_rows[#del_rows + 1] = row
	end

	local ren = {}
	for _, r in ipairs(ops.renamed) do
		local row = M.row_of_path(snap, r.old.path)
		if not row then
			return abort()
		end
		ren[#ren + 1] = { row = row, name = r.new.name, path = r.new.path }
	end

	local names = snap.names or {}
	snap.names = names

	-- Parent resolution has to see the post-save tree, because the three op
	-- kinds refer to each other: renaming a directory in place comes back from
	-- the diff as delete + create plus a move of every loaded child, so a
	-- child's new parent is a directory that does not exist as a row yet.  The
	-- reverse also happens, a create landing inside a renamed directory.
	--
	-- So: creates are materialized first, and lookups consult the rows this
	-- call is about to add and the paths the renames are about to produce
	-- before falling back to the pre-save index.
	local fresh = {}
	local ren_by_newpath = {}
	local ren_moves = {}
	for _, r in ipairs(ren) do
		ren_by_newpath[r.path] = r.row
	end
	for _, r in ipairs(moves) do
		ren_moves[r.new.path] = true
	end

	local function resolve(path)
		if path == snap.root then
			return 0
		end
		local row = fresh[path] or ren_by_newpath[path]
		if row then
			return row
		end
		return M.row_of_path(snap, path)
	end

	--- Recompute visibility flags, preserving kind and the truncated marker.
	local function reflag(row, name, path)
		local bits = kind[row] % (KIND_MASK + 1)
		if math.floor(kind[row] / F_TRUNCATED) % 2 == 1 then
			bits = bits + F_TRUNCATED
		end
		if name:byte(1) == DOT then
			bits = bits + F_HIDDEN
		end
		if ignore_set and ignore_set[path] then
			bits = bits + F_IGNORED
		end
		kind[row] = bits
	end

	for _, row in ipairs(del_rows) do
		if math.floor(kind[row] / F_DEAD) % 2 == 0 then
			kind[row] = kind[row] + F_DEAD
		end
	end

	-- Creates first, shallowest first so a parent exists before its children.
	if #ops.created > 0 then
		local creates = {}
		for _, c in ipairs(ops.created) do
			creates[#creates + 1] = c
		end
		table.sort(creates, function(a, b)
			return path_depth(a.path) < path_depth(b.path)
		end)

		for _, c in ipairs(creates) do
			local pp = parent_of(c.path)
			local prow = resolve(pp)
			if prow == nil then
				return abort()
			end
			-- A parent that is itself about to be moved has an indent that is
			-- not settled yet; not worth reasoning about for the gain.
			if prow ~= 0 and ren_moves[pp] then
				return abort()
			end
			local row = snap.n + 1
			snap.n = row
			names[row] = c.name
			-- Name lives in the override table; the slice is never read.
			snap.off[row], snap.len[row] = 1, 0
			parent[row] = prow
			indent[row] = (prow == 0) and 0 or indent[prow] + 1
			kind[row] = c.type == "dir" and KIND_DIR or (c.type == "link" and KIND_LINK or 0)
			reflag(row, c.name, c.path)
			fresh[c.path] = row
		end
	end

	local shifts = {}
	for _, r in ipairs(ren) do
		local np = resolve(parent_of(r.path))
		if np == nil then
			return abort()
		end
		names[r.row] = r.name
		if parent[r.row] ~= np then
			local new_indent = (np == 0) and 0 or indent[np] + 1
			local delta = new_indent - indent[r.row]
			parent[r.row] = np
			if delta ~= 0 then
				shifts[#shifts + 1] = { r.row, delta }
			end
		end
		reflag(r.row, r.name, r.path)
	end
	for _, sh in ipairs(shifts) do
		M.shift_subtree_indent(snap, sh[1], sh[2])
	end

	-- Structure changed: the child index and every recorded sibling order are
	-- stale.
	M.build_index(snap)
	snap.sorted = {}
	snap.view, snap.row_of = nil, nil
	return true
end

return M
