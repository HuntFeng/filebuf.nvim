----------------------------------------------------------------------
-- Unit tests — scan.filter_visible.
--
-- Now that every directory is lazy-loaded and nothing is dropped at scan
-- time, this filter is the *only* thing implementing the show_hidden toggle:
-- it turns the unfiltered entry list into the display list.  Pure function,
-- no filesystem — entries are synthetic.
----------------------------------------------------------------------
local scan = require("filebuf.scan")
local config = require("filebuf.config")

--- Build a synthetic entry.  `flags` may set is_hidden / is_ignored / lazy.
local function entry(name, etype, indent, flags)
	local e = { name = name, type = etype, path = "/root/" .. name, indent = indent or 0 }
	for k, v in pairs(flags or {}) do
		e[k] = v
	end
	return e
end

--- Names of the entries a filter pass kept, in order.
local function names_of(entries)
	local names = {}
	for _, e in ipairs(entries) do
		names[#names + 1] = e.name
	end
	return names
end

describe("scan.filter_visible", function()
	local saved_show_hidden

	before_each(function()
		saved_show_hidden = config.show_hidden
		config.show_hidden = false
	end)

	after_each(function()
		config.show_hidden = saved_show_hidden
	end)

	it("returns the input untouched when show_hidden is true", function()
		config.show_hidden = true
		local entries = {
			entry("visible.txt", "file", 0),
			entry(".hidden", "file", 0, { is_hidden = true }),
			entry("node_modules", "dir", 0, { is_ignored = true, lazy = true }),
		}
		local visible = scan.filter_visible(entries)
		-- Same table reference: hidden entries are dimmed by the decoration
		-- provider rather than removed.
		assert.equals(entries, visible)
	end)

	it("drops hidden and ignored entries when show_hidden is false", function()
		local entries = {
			entry("a.txt", "file", 0),
			entry(".hidden", "file", 0, { is_hidden = true }),
			entry("build.log", "file", 0, { is_ignored = true }),
			entry("b.txt", "file", 0),
		}
		assert.same({ "a.txt", "b.txt" }, names_of(scan.filter_visible(entries)))
	end)

	it("drops the whole subtree under a hidden directory", function()
		local entries = {
			entry("keep.txt", "file", 0),
			entry(".git", "dir", 0, { is_hidden = true }),
			entry("HEAD", "file", 1),
			entry("refs", "dir", 1),
			entry("main", "file", 2),
			entry("after.txt", "file", 0),
		}
		-- Children of .git carry no flags of their own, but sit inside it.
		assert.same({ "keep.txt", "after.txt" }, names_of(scan.filter_visible(entries)))
	end)

	it("drops the whole subtree under an ignored directory", function()
		local entries = {
			entry("src", "dir", 0),
			entry("main.lua", "file", 1),
			entry("target", "dir", 0, { is_ignored = true }),
			entry("debug", "dir", 1),
			entry("app", "file", 2),
			entry("README.md", "file", 0),
		}
		assert.same({ "src", "main.lua", "README.md" }, names_of(scan.filter_visible(entries)))
	end)

	it("drops a lazy hidden directory that has no loaded children", function()
		local entries = {
			entry(".cache", "dir", 0, { is_hidden = true, lazy = true }),
			entry("visible", "dir", 0, { lazy = true }),
		}
		assert.same({ "visible" }, names_of(scan.filter_visible(entries)))
	end)

	it("keeps siblings at the same indent as a hidden directory", function()
		local entries = {
			entry("parent", "dir", 0),
			entry(".secret", "dir", 1, { is_hidden = true }),
			entry("inside", "file", 2),
			entry("sibling.txt", "file", 1),
			entry("other", "dir", 1),
			entry("nested.txt", "file", 2),
		}
		-- The stack pops once indent returns to .secret's level, so sibling.txt
		-- and everything after it survives.
		assert.same({ "parent", "sibling.txt", "other", "nested.txt" }, names_of(scan.filter_visible(entries)))
	end)

	it("handles nested hidden directories", function()
		local entries = {
			entry(".outer", "dir", 0, { is_hidden = true }),
			entry(".inner", "dir", 1, { is_hidden = true }),
			entry("deep.txt", "file", 2),
			entry("root.txt", "file", 0),
		}
		assert.same({ "root.txt" }, names_of(scan.filter_visible(entries)))
	end)

	it("returns an empty list for an empty input", function()
		assert.same({}, scan.filter_visible({}))
	end)
end)
