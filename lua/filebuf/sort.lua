----------------------------------------------------------------------
-- Sibling ordering for flat entry lists.
--
-- Entries are always a flat depth-first list carrying an `indent`, so
-- sorting means reordering siblings while keeping every subtree glued to
-- its parent.
--
-- The main tree render sorts siblings inside filebuf.snapshot (sort_range,
-- over the row cache's child index).  This module is the entry-list
-- equivalent: the fallback path in filebuf.init's sort_by when the snapshot
-- cache cannot answer.
--
-- The ordering is computed over *indices*, not entries: one pass derives
-- each entry's parent from the indent stack, a second buckets children by
-- parent, each sibling bucket is sorted once, and an iterative DFS emits
-- the result.  Every entry is written to the output exactly once.
--
-- The previous shape recursed per parent group and copied each subtree up
-- through every level on the way out, so an entry at depth d was appended
-- d times -- O(n*depth) appends plus a wrapper table per entry per level.
-- At 100k entries and max_depth 20 that dominated the scan.
--
-- TODO: reuse sortings here in snapshot.lua
----------------------------------------------------------------------
local M = {}

M.METHODS = { "type", "name", "modified", "created" }

local TYPE_PRIO = { dir = 1, link = 2, file = 3 }

--- Precompute one comparable string key per entry.
---
--- Sorting via a comparator calls name:lower() inside table.sort, so it
--- runs O(n log n) times and allocates a string on every comparison.  A key
--- array makes it exactly one lower() per entry, and reduces the sort
--- itself to a plain string compare.
---
--- For "type" the type priority is a single leading digit, so the keys
--- order by type first and name second under a plain string compare.
---@param entries table[]
---@param method  string
---@return string[]|nil  nil when the method has no ordering here
function M.keys(entries, method)
	local keys = {}
	if method == "name" then
		for i = 1, #entries do
			keys[i] = entries[i].name:lower()
		end
		return keys
	elseif method == "type" then
		for i = 1, #entries do
			local e = entries[i]
			keys[i] = (TYPE_PRIO[e.type] or 5) .. e.name:lower()
		end
		return keys
	elseif method == "modified" then
		for i = 1, #entries do
			local e = entries[i]
			local ts = e.mtime
			if not ts then
				return nil
			end
			keys[i] = string.format("%020d", ts) .. e.name:lower()
		end
		return keys
	elseif method == "created" then
		for i = 1, #entries do
			local e = entries[i]
			local ts = e.ctime
			if not ts then
				return nil
			end
			keys[i] = string.format("%020d", ts) .. e.name:lower()
		end
		return keys
	end
	return nil
end

--- Reorder a flat depth-first entry list, sorting siblings while keeping
--- each subtree attached to its parent.
---
--- `keys` is optional: when given it must be parallel to `entries` and
--- siblings are ordered by plain key comparison (see M.keys).  Otherwise
--- `cmp` is called on the entry tables directly.
---@param entries table[]
---@param cmp     (fun(a: table, b: table): boolean)|nil  required when keys is nil
---@param keys    string[]|nil
---@return table[]
function M.hierarchical(entries, cmp, keys)
	local n = #entries
	if n == 0 then
		return {}
	end

	-- 1. Parent of every entry, from the indent stack.  Only directories
	--    become ancestors, mirroring buffer.parse_buffer: an entry nested
	--    under a file belongs to the nearest enclosing directory.
	local parent = {}
	local stack = {}
	local top = 0
	for i = 1, n do
		local e = entries[i]
		local indent = e.indent or 0
		while top > 0 and (entries[stack[top]].indent or 0) >= indent do
			top = top - 1
		end
		parent[i] = top > 0 and stack[top] or 0
		if e.type == "dir" then
			top = top + 1
			stack[top] = i
		end
	end

	-- 2. Bucket child indices by parent, preserving the incoming order so
	--    an absent comparator leaves the on-disk order intact.
	local children = {}
	for i = 1, n do
		local p = parent[i]
		local list = children[p]
		if not list then
			list = { i }
			children[p] = list
		else
			list[#list + 1] = i
		end
	end

	-- 3. Sort each sibling bucket once.  Total O(n log k), k = widest dir.
	local by_index
	if keys then
		by_index = function(a, b)
			return keys[a] < keys[b]
		end
	else
		by_index = function(a, b)
			return cmp(entries[a], entries[b])
		end
	end
	for _, list in pairs(children) do
		if #list > 1 then
			table.sort(list, by_index)
		end
	end

	-- 4. Iterative DFS.  Each entry is appended to the result exactly once.
	local result = {}
	local out = 0
	local frame_list = { children[0] }
	local frame_pos = { 1 }
	local depth = 1
	while depth > 0 do
		local list = frame_list[depth]
		local pos = frame_pos[depth]
		if not list or pos > #list then
			depth = depth - 1
		else
			frame_pos[depth] = pos + 1
			local i = list[pos]
			out = out + 1
			result[out] = entries[i]
			local kids = children[i]
			if kids then
				depth = depth + 1
				frame_list[depth] = kids
				frame_pos[depth] = 1
			end
		end
	end

	return result
end

--- Sort a flat entry list per the configured sort method.
--- No-op when the method has no ordering available.
---@param entries table[]
---@param method? string  defaults to config.sort_method
---@return table[]  possibly a new list
function M.apply(entries, method)
	method = method or require("filebuf.config").sort_method
	local keys = M.keys(entries, method)
	if not keys then
		return entries
	end
	return M.hierarchical(entries, nil, keys)
end

return M
