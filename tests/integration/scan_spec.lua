----------------------------------------------------------------------
-- Integration tests — the scanner.
--
-- Every directory is a lazy placeholder: scan_tree loads only the root's
-- immediate children, and scan_dir_children loads exactly one level.  Nothing
-- is dropped at scan time; hidden and gitignored entries are listed and
-- tagged so show_hidden stays a pure re-filter.
----------------------------------------------------------------------
local helpers = require("tests.helpers")
local scan = require("filebuf.scan")
local config = require("filebuf.config")

--- Index a child list by name.
local function by_name(entries)
	local map = {}
	for _, e in ipairs(entries) do
		map[e.name] = e
	end
	return map
end

describe("scan", function()
	local tmpdir

	before_each(function()
		tmpdir = helpers.create_temp_dir()
		config.respect_ignore = false
		config.show_hidden = false
		config.sort_method = "type"
		scan.clear_ignore_cache()
	end)

	after_each(function()
		helpers.cleanup_dir(tmpdir)
		config.respect_ignore = false
		config.show_hidden = false
		config.sort_method = "type"
		scan.clear_ignore_cache()
	end)

	------------------------------------------------------------------
	-- scan_tree: one level only
	------------------------------------------------------------------

	it("returns only the root's immediate children, all at indent 0", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/b"] = {},
			["a/b/deep.txt"] = "",
			["top.txt"] = "",
		})
		local entries = scan.scan_tree(tmpdir)
		assert.equals(2, #entries)
		for _, e in ipairs(entries) do
			assert.equals(0, e.indent)
		end
		local map = by_name(entries)
		assert.is_not_nil(map["a"])
		assert.is_not_nil(map["top.txt"])
		-- Nothing from deeper levels.
		assert.is_nil(map["b"])
		assert.is_nil(map["deep.txt"])
	end)

	it("marks every directory lazy and leaves files unmarked", function()
		helpers.populate_dir(tmpdir, {
			["dir_one"] = {},
			["dir_two"] = {},
			["file.txt"] = "",
		})
		local map = by_name(scan.scan_tree(tmpdir))
		assert.is_true(map["dir_one"].lazy)
		assert.is_true(map["dir_two"].lazy)
		assert.is_nil(map["file.txt"].lazy)
	end)

	it("returns an empty list for an empty directory", function()
		assert.same({}, scan.scan_tree(tmpdir))
	end)

	it("returns an empty list for an unreadable path", function()
		assert.same({}, scan.scan_tree(tmpdir .. "/does_not_exist"))
	end)

	------------------------------------------------------------------
	-- Hidden / ignored entries are listed, not dropped
	------------------------------------------------------------------

	it("lists hidden files and dirs, tagged is_hidden", function()
		helpers.populate_dir(tmpdir, {
			[".hidden_file"] = "",
			[".hidden_dir"] = {},
			["visible.txt"] = "",
		})
		local map = by_name(scan.scan_tree(tmpdir))
		assert.is_not_nil(map[".hidden_file"], ".hidden_file should be scanned")
		assert.is_true(map[".hidden_file"].is_hidden)
		assert.is_not_nil(map[".hidden_dir"], ".hidden_dir should be scanned")
		assert.is_true(map[".hidden_dir"].is_hidden)
		assert.is_true(map[".hidden_dir"].lazy)
		assert.is_nil(map["visible.txt"].is_hidden)
	end)

	it("lists gitignored plain files, tagged is_ignored", function()
		-- The old fd scanner deliberately skipped these, which made the
		-- show_hidden toggle lossy.  They must be present now.
		config.respect_ignore = true
		helpers.populate_dir(tmpdir, {
			[".gitignore"] = "*.log\n",
			["app.log"] = "",
			["keep.txt"] = "",
		})
		scan.clear_ignore_cache()
		local map = by_name(scan.scan_tree(tmpdir))
		assert.is_not_nil(map["app.log"], "app.log should be scanned, just tagged")
		assert.is_true(map["app.log"].is_ignored)
		assert.is_nil(map["keep.txt"].is_ignored)
	end)

	it("does not tag .ignore itself as ignored", function()
		config.respect_ignore = true
		helpers.populate_dir(tmpdir, { [".ignore"] = "*\n" })
		scan.clear_ignore_cache()
		local map = by_name(scan.scan_tree(tmpdir))
		assert.is_nil(map[".ignore"].is_ignored)
	end)

	------------------------------------------------------------------
	-- scan_dir_children: one level, on demand
	------------------------------------------------------------------

	it("scan_dir_children loads exactly one level", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/child.txt"] = "",
			["a/sub"] = {},
			["a/sub/grandchild.txt"] = "",
		})
		local map = by_name(scan.scan_dir_children(tmpdir .. "/a", tmpdir))
		assert.is_not_nil(map["child.txt"])
		assert.is_not_nil(map["sub"])
		assert.is_true(map["sub"].lazy)
		assert.is_nil(map["grandchild.txt"])
	end)

	it("scan_dir_children does not set indent (the caller supplies it)", function()
		helpers.populate_dir(tmpdir, { ["a"] = {}, ["a/child.txt"] = "" })
		local children = scan.scan_dir_children(tmpdir .. "/a", tmpdir)
		assert.equals(1, #children)
		assert.is_nil(children[1].indent)
	end)

	------------------------------------------------------------------
	-- Ignore patterns accumulate from the root downward
	------------------------------------------------------------------

	it("applies a root .gitignore to a deeply nested directory", function()
		-- The pre-lazy find scanner pushed patterns as it descended.  Lazy
		-- scanning jumps straight to a deep directory, so the ancestor chain
		-- has to be rebuilt — otherwise a root rule silently stops applying.
		config.respect_ignore = true
		helpers.populate_dir(tmpdir, {
			[".gitignore"] = "*.log\n",
			["deep"] = {},
			["deep/nested"] = {},
			["deep/nested/x.log"] = "",
			["deep/nested/x.txt"] = "",
		})
		scan.clear_ignore_cache()
		local map = by_name(scan.scan_dir_children(tmpdir .. "/deep/nested", tmpdir))
		assert.is_true(map["x.log"].is_ignored, "root *.log should reach deep/nested")
		assert.is_nil(map["x.txt"].is_ignored)
	end)

	it("applies an intermediate directory's .gitignore to its descendants", function()
		config.respect_ignore = true
		helpers.populate_dir(tmpdir, {
			["deep"] = {},
			["deep/.gitignore"] = "*.tmp\n",
			["deep/nested"] = {},
			["deep/nested/y.tmp"] = "",
			["deep/nested/y.txt"] = "",
		})
		scan.clear_ignore_cache()
		local map = by_name(scan.scan_dir_children(tmpdir .. "/deep/nested", tmpdir))
		assert.is_true(map["y.tmp"].is_ignored)
		assert.is_nil(map["y.txt"].is_ignored)
	end)

	it("ignores nothing when respect_ignore is false", function()
		config.respect_ignore = false
		helpers.populate_dir(tmpdir, {
			[".gitignore"] = "*.log\n",
			["app.log"] = "",
		})
		scan.clear_ignore_cache()
		local map = by_name(scan.scan_tree(tmpdir))
		assert.is_nil(map["app.log"].is_ignored)
	end)

	it("clear_ignore_cache picks up a rewritten .gitignore", function()
		config.respect_ignore = true
		helpers.populate_dir(tmpdir, {
			[".gitignore"] = "*.log\n",
			["app.log"] = "",
		})
		scan.clear_ignore_cache()
		assert.is_true(by_name(scan.scan_tree(tmpdir))["app.log"].is_ignored)

		helpers.populate_dir(tmpdir, { [".gitignore"] = "*.tmp\n" })
		-- Stale cache still reports the old rule...
		assert.is_true(by_name(scan.scan_tree(tmpdir))["app.log"].is_ignored)
		-- ...until the cache is dropped.
		scan.clear_ignore_cache()
		assert.is_nil(by_name(scan.scan_tree(tmpdir))["app.log"].is_ignored)
	end)

	------------------------------------------------------------------
	-- count_subtree
	------------------------------------------------------------------

	it("count_subtree counts every descendant, excluding the dir itself", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/one.txt"] = "",
			["a/sub"] = {},
			["a/sub/two.txt"] = "",
			["a/sub/deeper"] = {},
			["a/sub/deeper/three.txt"] = "",
			["outside.txt"] = "",
		})
		-- one.txt, sub, two.txt, deeper, three.txt
		local count, capped = scan.count_subtree(tmpdir .. "/a", tmpdir)
		assert.equals(5, count)
		assert.is_false(capped)
	end)

	it("count_subtree returns 0 for an empty directory", function()
		helpers.populate_dir(tmpdir, { ["empty"] = {} })
		local count, capped = scan.count_subtree(tmpdir .. "/empty", tmpdir)
		assert.equals(0, count)
		assert.is_false(capped)
	end)

	it("count_subtree stops at the cap and reports it", function()
		local structure = { ["big"] = {} }
		for i = 1, 20 do
			structure["big/file_" .. i .. ".txt"] = ""
		end
		helpers.populate_dir(tmpdir, structure)
		local count, capped = scan.count_subtree(tmpdir .. "/big", tmpdir, 5)
		assert.equals(5, count)
		assert.is_true(capped)
	end)

	it("count_subtree skips hidden subtrees while show_hidden is off", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/visible.txt"] = "",
			["a/.hidden"] = {},
			["a/.hidden/inside.txt"] = "",
		})
		config.show_hidden = false
		assert.equals(1, scan.count_subtree(tmpdir .. "/a", tmpdir))

		config.show_hidden = true
		-- visible.txt, .hidden, .hidden/inside.txt
		assert.equals(3, scan.count_subtree(tmpdir .. "/a", tmpdir))
		config.show_hidden = false
	end)

	it("count_subtree does not follow symlinked directories", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["real"] = {},
			["real/inside.txt"] = "",
		})
		vim.loop.fs_symlink(tmpdir .. "/real", tmpdir .. "/a/alias")
		-- Only the link entry itself, never what it points at.
		assert.equals(1, scan.count_subtree(tmpdir .. "/a", tmpdir))
	end)

	------------------------------------------------------------------
	-- Sorting
	------------------------------------------------------------------

	it("sorts dirs, then links, then files with sort_method = type", function()
		config.sort_method = "type"
		helpers.populate_dir(tmpdir, {
			["zebra.txt"] = "",
			["aardvark.txt"] = "",
			["zdir"] = {},
			["adir"] = {},
		})
		vim.loop.fs_symlink(tmpdir .. "/zebra.txt", tmpdir .. "/mlink")
		local entries = scan.scan_tree(tmpdir)
		local order = {}
		for _, e in ipairs(entries) do
			order[#order + 1] = e.name
		end
		assert.same({ "adir", "zdir", "mlink", "aardvark.txt", "zebra.txt" }, order)
	end)

	it("sorts case-insensitively by name with sort_method = name", function()
		config.sort_method = "name"
		helpers.populate_dir(tmpdir, {
			["Zebra.txt"] = "",
			["apple.txt"] = "",
			["mdir"] = {},
		})
		local entries = scan.scan_tree(tmpdir)
		local order = {}
		for _, e in ipairs(entries) do
			order[#order + 1] = e.name
		end
		-- Type is ignored entirely: mdir sits between apple and Zebra.
		assert.same({ "apple.txt", "mdir", "Zebra.txt" }, order)
	end)

	it("never follows symlinks — they are atomic link entries", function()
		helpers.populate_dir(tmpdir, {
			["real"] = {},
			["real/inside.txt"] = "",
		})
		vim.loop.fs_symlink(tmpdir .. "/real", tmpdir .. "/alias")
		local map = by_name(scan.scan_tree(tmpdir))
		assert.equals("link", map["alias"].type)
		assert.is_nil(map["alias"].lazy, "a link is never a lazy directory")
	end)
end)
