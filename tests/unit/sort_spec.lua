----------------------------------------------------------------------
-- Unit tests — filebuf.sort.
--
-- Entries are a flat depth-first list carrying an `indent`, so sorting means
-- reordering siblings while keeping every subtree glued to its parent.  The
-- implementation works over indices and writes each entry to the output
-- exactly once, so the properties worth pinning down are the structural ones:
-- subtrees stay attached, nothing is lost, and nothing is duplicated.
----------------------------------------------------------------------
local sort = require("filebuf.sort")

--- Build an entry list from a compact spec of { indent, name, type }.
--- type defaults to "file"; a trailing "/" on the name means "dir".
---@param spec table[]
---@return table[]
local function entries(spec)
	local out = {}
	for i, s in ipairs(spec) do
		local name, etype = s[2], s[3]
		if not etype then
			etype = name:sub(-1) == "/" and "dir" or "file"
		end
		if name:sub(-1) == "/" then
			name = name:sub(1, -2)
		end
		out[i] = { indent = s[1], name = name, type = etype }
	end
	return out
end

--- Render a sorted list as indent-prefixed names, for readable assertions.
local function shape(list)
	local out = {}
	for i, e in ipairs(list) do
		out[i] = string.rep("  ", e.indent) .. e.name .. (e.type == "dir" and "/" or "")
	end
	return out
end

describe("sort.comparator", function()
	it("orders by lowercased name for method name", function()
		local cmp = sort.comparator("name")
		assert.is_true(cmp({ name = "alpha", type = "file" }, { name = "Beta", type = "file" }))
		assert.is_false(cmp({ name = "Beta", type = "file" }, { name = "alpha", type = "file" }))
	end)

	it("puts dirs before links before files for method type", function()
		local cmp = sort.comparator("type")
		assert.is_true(cmp({ name = "z", type = "dir" }, { name = "a", type = "link" }))
		assert.is_true(cmp({ name = "z", type = "link" }, { name = "a", type = "file" }))
		assert.is_false(cmp({ name = "a", type = "file" }, { name = "z", type = "dir" }))
	end)

	it("falls back to name within the same type", function()
		local cmp = sort.comparator("type")
		assert.is_true(cmp({ name = "a", type = "file" }, { name = "b", type = "file" }))
	end)

	it("returns nil for methods with no ordering available", function()
		assert.is_nil(sort.comparator("modified"))
		assert.is_nil(sort.comparator("created"))
		assert.is_nil(sort.comparator("nonsense"))
	end)
end)

describe("sort.keys", function()
	it("lowercases names for method name", function()
		assert.same({ "beta", "alpha" }, sort.keys(entries({ { 0, "Beta" }, { 0, "ALPHA" } }), "name"))
	end)

	it("prefixes a type priority digit for method type", function()
		local k = sort.keys(entries({ { 0, "d/" }, { 0, "f" } }), "type")
		assert.equals("1d", k[1])
		assert.equals("3f", k[2])
	end)

	it("returns nil for methods with no ordering", function()
		assert.is_nil(sort.keys(entries({ { 0, "a" } }), "modified"))
	end)
end)

describe("sort.hierarchical", function()
	it("sorts top-level siblings", function()
		local out = sort.apply(entries({ { 0, "zeta" }, { 0, "alpha" }, { 0, "mid" } }), "name")
		assert.same({ "alpha", "mid", "zeta" }, shape(out))
	end)

	it("keeps a subtree attached to its parent", function()
		local out = sort.apply(
			entries({
				{ 0, "zzz/" },
				{ 1, "inside_z" },
				{ 0, "aaa/" },
				{ 1, "inside_a" },
			}),
			"name"
		)
		assert.same({ "aaa/", "  inside_a", "zzz/", "  inside_z" }, shape(out))
	end)

	it("sorts siblings at every depth", function()
		local out = sort.apply(
			entries({
				{ 0, "d/" },
				{ 1, "z.txt" },
				{ 1, "a.txt" },
				{ 1, "sub/" },
				{ 2, "y.txt" },
				{ 2, "b.txt" },
			}),
			"name"
		)
		assert.same({ "d/", "  a.txt", "  sub/", "    b.txt", "    y.txt", "  z.txt" }, shape(out))
	end)

	it("puts dirs first at every depth with method type", function()
		local out = sort.apply(
			entries({
				{ 0, "file.txt" },
				{ 0, "dir/" },
				{ 1, "inner.txt" },
				{ 1, "innerdir/" },
			}),
			"type"
		)
		assert.same({ "dir/", "  innerdir/", "  inner.txt", "file.txt" }, shape(out))
	end)

	it("preserves every entry exactly once", function()
		local input = entries({
			{ 0, "b/" },
			{ 1, "b2" },
			{ 1, "b1/" },
			{ 2, "b1a" },
			{ 0, "a/" },
			{ 1, "a1" },
			{ 0, "c" },
		})
		local out = sort.apply(input, "name")
		assert.equals(#input, #out)
		local seen = {}
		for _, e in ipairs(out) do
			assert.is_nil(seen[e], "entry emitted twice: " .. e.name)
			seen[e] = true
		end
		for _, e in ipairs(input) do
			assert.is_true(seen[e], "entry lost: " .. e.name)
		end
	end)

	it("keeps entries nested under a non-directory", function()
		-- A malformed tree, but losing lines is worse than ordering them oddly:
		-- the previous implementation only recursed into dirs and silently
		-- dropped anything indented under a file.
		local out = sort.apply(entries({ { 0, "afile" }, { 1, "orphan" }, { 0, "zfile" } }), "name")
		assert.equals(3, #out)
		local names = {}
		for _, e in ipairs(out) do
			names[e.name] = true
		end
		assert.is_true(names["orphan"])
	end)

	it("handles a deep single chain", function()
		local spec = {}
		for i = 0, 19 do
			spec[#spec + 1] = { i, "level" .. i .. "/" }
		end
		local out = sort.apply(entries(spec), "name")
		assert.equals(20, #out)
		for i, e in ipairs(out) do
			assert.equals(i - 1, e.indent)
		end
	end)

	it("returns the input untouched for methods with no ordering", function()
		local input = entries({ { 0, "zeta" }, { 0, "alpha" } })
		local out = sort.apply(input, "modified")
		assert.equals(input, out, "should be the same table, not a copy")
		assert.same({ "zeta", "alpha" }, shape(out))
	end)

	it("handles an empty list", function()
		assert.same({}, sort.apply({}, "name"))
	end)

	it("sorts case-insensitively", function()
		local out = sort.apply(entries({ { 0, "Beta" }, { 0, "alpha" }, { 0, "Gamma" } }), "name")
		assert.same({ "alpha", "Beta", "Gamma" }, shape(out))
	end)

	it("accepts an explicit comparator", function()
		-- The two-argument form is still part of the API for callers that build
		-- their own ordering.
		local out = sort.hierarchical(entries({ { 0, "a" }, { 0, "b" } }), function(x, y)
			return x.name > y.name
		end)
		assert.same({ "b", "a" }, shape(out))
	end)
end)
