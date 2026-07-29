----------------------------------------------------------------------
-- Entry ordering.
--
-- Entries are always a flat depth-first list carrying an `indent`, so
-- sorting means reordering siblings while keeping every subtree glued to
-- its parent.  Both the initial render (scan) and :FilebufSortMethod go
-- through here so the two can never disagree.
----------------------------------------------------------------------
local M = {}

M.METHODS = { "type", "name", "modified", "created" }

local TYPE_PRIO = { dir = 1, link = 2, file = 3 }

--- Build the sibling comparator for a sort method.
--- Returns nil when the method has no ordering available here, in which
--- case the on-disk order is kept.
---@param method string  "type" | "name" | "modified" | "created"
---@return (fun(a: table, b: table): boolean)|nil
function M.comparator(method)
	if method == "name" then
		return function(a, b)
			return a.name:lower() < b.name:lower()
		end
	elseif method == "type" then
		return function(a, b)
			local pa = TYPE_PRIO[a.type] or 5
			local pb = TYPE_PRIO[b.type] or 5
			if pa ~= pb then
				return pa < pb
			end
			return a.name:lower() < b.name:lower()
		end
	end
	-- "modified" / "created" would need per-entry stat data.
	return nil
end

--- Recursively sort entries within each parent group.
--- Entries is a flat depth-first list; siblings at the same indent
--- level are sorted while preserving parent-child relationships.
---@param entries table[]
---@param cmp     fun(a: table, b: table): boolean
---@return table[]
function M.hierarchical(entries, cmp)
	---@param start_idx number
	---@param end_idx   number
	---@return table[]
	local function sort_range(start_idx, end_idx)
		if start_idx > end_idx then
			return {}
		end

		local base_indent = entries[start_idx].indent
		local result = {}
		local j = start_idx

		-- Collect siblings at base_indent within this range.
		local siblings = {}
		while j <= end_idx do
			if entries[j].indent == base_indent then
				siblings[#siblings + 1] = { idx = j, entry = entries[j] }
				j = j + 1
			elseif entries[j].indent > base_indent then
				j = j + 1 -- descendant of previous sibling, handled by recursion
			else
				break -- indent < base_indent: back to parent scope
			end
		end

		-- Compute each sibling's descendant range.
		for k = 1, #siblings do
			local sib = siblings[k]
			local next_start = (k < #siblings) and siblings[k + 1].idx or j
			sib.desc_end = next_start - 1
		end

		-- Sort siblings.
		if #siblings > 1 then
			table.sort(siblings, function(a, b)
				return cmp(a.entry, b.entry)
			end)
		end

		-- Output each sibling followed by its recursively sorted descendants.
		for _, sib in ipairs(siblings) do
			result[#result + 1] = sib.entry
			if sib.entry.type == "dir" and sib.idx + 1 <= sib.desc_end then
				local children = sort_range(sib.idx + 1, sib.desc_end)
				for _, child in ipairs(children) do
					result[#result + 1] = child
				end
			end
		end

		return result
	end

	if #entries == 0 then
		return {}
	end
	return sort_range(1, #entries)
end

--- Sort a flat entry list in place per the configured sort method.
--- No-op when the method has no comparator.
---@param entries table[]
---@param method? string  defaults to config.sort_method
---@return table[]  possibly a new list
function M.apply(entries, method)
	local cmp = M.comparator(method or require("filebuf.config").sort_method)
	if not cmp then
		return entries
	end
	return M.hierarchical(entries, cmp)
end

return M
