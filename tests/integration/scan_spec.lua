----------------------------------------------------------------------
-- Integration tests — the scanner, against a real filesystem.
--
-- scan.scan_into is the only producer of snapshot rows: it runs find(1),
-- fills the row cache with *every* entry on disk, and returns the buffer
-- lines for the current projection.  Hidden and gitignored entries are kept
-- as flagged rows rather than dropped, which is what makes show_hidden a
-- re-projection instead of a rescan.
--
-- scan.scan_dir_children is the one-level scan used by lazy expansion, and
-- scan.scan_disk_entries is the baseline the :w diff compares against.
----------------------------------------------------------------------
local helpers = require("tests.helpers")
local scan = require("filebuf.scan")
local snapshot = require("filebuf.snapshot")
local git = require("filebuf.git")
local config = require("filebuf.config")

--- Index a child list by name.
local function by_name(entries)
	local map = {}
	for _, e in ipairs(entries) do
		map[e.name] = e
	end
	return map
end

--- Lines produced by scanning `dir`.  Deliberately one return value: a second
--- one would land in assert.same's message slot and quietly change the
--- comparison.
local function scan_dir(dir, opts)
	local snap = snapshot.new(dir)
	return (scan.scan_into(snap, dir, opts))
end

--- Both the lines and the snapshot, for tests that inspect the cache.
local function scan_dir_snap(dir, opts)
	local snap = snapshot.new(dir)
	local lines = scan.scan_into(snap, dir, opts)
	return lines, snap
end

describe("scan", function()
	local tmpdir

	before_each(function()
		tmpdir = helpers.create_temp_dir()
		config.show_hidden = false
		config.sort_method = "type"
		git.clear_ignore_cache()
	end)

	after_each(function()
		helpers.cleanup_dir(tmpdir)
		config.show_hidden = false
		config.sort_method = "type"
		git.clear_ignore_cache()
	end)

	------------------------------------------------------------------
	-- scan_into: disk -> rows -> lines
	------------------------------------------------------------------

	it("renders the whole tree as indented lines", function()
		helpers.populate_dir(tmpdir, {
			["dir"] = {},
			["dir/child.txt"] = "",
			["top.txt"] = "",
		})
		assert.same({ "dir/", "  child.txt", "top.txt" }, scan_dir(tmpdir))
	end)

	it("returns an empty list for an empty directory", function()
		assert.same({}, scan_dir(tmpdir))
	end)

	it("yields no lines for a directory that cannot be read", function()
		-- Not nil: vim.fn.system folds find's stderr into its output, so the
		-- output is non-empty and simply parses to zero rows.  Callers therefore
		-- see an empty tree rather than a scan failure.
		local snap = snapshot.new("/definitely/not/here")
		assert.same({}, scan.scan_into(snap, "/definitely/not/here"))
		assert.equals(0, snap.n)
	end)

	it("marks dirs with a trailing slash and symlinks with @", function()
		helpers.populate_dir(tmpdir, { ["real.txt"] = "", ["adir"] = {} })
		vim.loop.fs_symlink(tmpdir .. "/real.txt", tmpdir .. "/alink")
		assert.same({ "adir/", "alink@", "real.txt" }, scan_dir(tmpdir))
	end)

	it("never descends into a symlinked directory", function()
		helpers.populate_dir(tmpdir, { ["target"] = {}, ["target/inside.txt"] = "" })
		vim.loop.fs_symlink(tmpdir .. "/target", tmpdir .. "/alias")
		-- alias is an atomic link entry, so inside.txt appears exactly once.
		assert.same({ "target/", "  inside.txt", "alias@" }, scan_dir(tmpdir))
	end)

	------------------------------------------------------------------
	-- Hidden entries: cached as rows, filtered by the projection
	------------------------------------------------------------------

	it("omits hidden entries from the lines when show_hidden is off", function()
		helpers.populate_dir(tmpdir, { [".secret"] = "", ["visible.txt"] = "" })
		assert.same({ "visible.txt" }, scan_dir(tmpdir, { show_hidden = false }))
	end)

	it("includes hidden entries when show_hidden is on", function()
		helpers.populate_dir(tmpdir, { [".secret"] = "", ["visible.txt"] = "" })
		assert.same({ ".secret", "visible.txt" }, scan_dir(tmpdir, { show_hidden = true }))
	end)

	it("still caches hidden rows while hiding them, so a toggle needs no rescan", function()
		helpers.populate_dir(tmpdir, { [".secret"] = "", ["visible.txt"] = "" })
		local lines, snap = scan_dir_snap(tmpdir, { show_hidden = false })
		assert.same({ "visible.txt" }, lines)
		-- The row is present and flagged, just not projected.
		local row = snapshot.row_of_path(snap, tmpdir .. "/.secret")
		assert.is_not_nil(row)
		assert.is_true(snapshot.has_flag(snap, row, snapshot.F_HIDDEN))
		-- Re-projecting alone reveals it: no second find(1).
		snapshot.project(snap, "type", true)
		assert.same({ ".secret", "visible.txt" }, snapshot.lines(snap))
	end)

	it("hides a hidden directory's children along with it", function()
		helpers.populate_dir(tmpdir, { [".git"] = {}, [".git/HEAD"] = "", ["keep.txt"] = "" })
		assert.same({ "keep.txt" }, scan_dir(tmpdir, { show_hidden = false }))
	end)

	------------------------------------------------------------------
	-- gitignore
	------------------------------------------------------------------

	it("omits gitignored files", function()
		helpers.git_init(tmpdir)
		helpers.populate_dir(tmpdir, {
			[".gitignore"] = "ignored.txt\n",
			["ignored.txt"] = "",
			["kept.txt"] = "",
		})
		git.clear_ignore_cache()
		assert.same({ "kept.txt" }, scan_dir(tmpdir, { show_hidden = false }))
	end)

	it("omits a gitignored directory and everything under it", function()
		helpers.git_init(tmpdir)
		helpers.populate_dir(tmpdir, {
			[".gitignore"] = "build/\n",
			["build"] = {},
			["build/out.o"] = "",
			["src"] = {},
			["src/main.lua"] = "",
		})
		git.clear_ignore_cache()
		assert.same({ "src/", "  main.lua" }, scan_dir(tmpdir, { show_hidden = false }))
	end)

	it("applies a nested .gitignore to its own subtree", function()
		helpers.git_init(tmpdir)
		helpers.populate_dir(tmpdir, {
			["sub"] = {},
			["sub/.gitignore"] = "skipme.txt\n",
			["sub/skipme.txt"] = "",
			["sub/keep.txt"] = "",
		})
		git.clear_ignore_cache()
		assert.same({ "sub/", "  keep.txt" }, scan_dir(tmpdir, { show_hidden = false }))
	end)

	it("returns all files in non-git directories regardless of .gitignore", function()
		-- No git_init here on purpose: a real .git directory would show up under
		-- show_hidden and has nothing to do with what this asserts.
		helpers.populate_dir(tmpdir, { [".gitignore"] = "ignored.txt\n", ["ignored.txt"] = "" })
		git.clear_ignore_cache()
		assert.same({ ".gitignore", "ignored.txt" }, scan_dir(tmpdir, { show_hidden = true }))
	end)

	it("picks up a rewritten .gitignore once the cache is cleared", function()
		helpers.git_init(tmpdir)
		helpers.populate_dir(tmpdir, { [".gitignore"] = "a.txt\n", ["a.txt"] = "", ["b.txt"] = "" })
		git.clear_ignore_cache()
		assert.same({ "b.txt" }, scan_dir(tmpdir, { show_hidden = false }))

		helpers.populate_dir(tmpdir, { [".gitignore"] = "b.txt\n" })
		git.clear_ignore_cache()
		assert.same({ "a.txt" }, scan_dir(tmpdir, { show_hidden = false }))
	end)

	it("does not cache ignored rows when the scan pruned them", function()
		-- With show_hidden off, ignored directories are handed to find -prune so
		-- their contents are never walked.  snap.pruned records that, and it is
		-- what tells a later toggle it has to rescan once.
		helpers.git_init(tmpdir)
		helpers.populate_dir(tmpdir, {
			[".gitignore"] = "vendor/\n",
			["vendor"] = {},
			["vendor/lib.lua"] = "",
			["main.lua"] = "",
		})
		git.clear_ignore_cache()
		local _, snap = scan_dir_snap(tmpdir, { show_hidden = false })
		assert.is_true(snap.pruned)
		assert.is_nil(snapshot.row_of_path(snap, tmpdir .. "/vendor/lib.lua"))
	end)

	it("caches ignored rows when the scan did not prune", function()
		helpers.git_init(tmpdir)
		helpers.populate_dir(tmpdir, {
			[".gitignore"] = "vendor/\n",
			["vendor"] = {},
			["vendor/lib.lua"] = "",
		})
		git.clear_ignore_cache()
		local _, snap = scan_dir_snap(tmpdir, { show_hidden = true })
		assert.is_false(snap.pruned)
		assert.is_not_nil(snapshot.row_of_path(snap, tmpdir .. "/vendor/lib.lua"))
	end)

	------------------------------------------------------------------
	-- Depth cap
	------------------------------------------------------------------

	it("stops at maxdepth and flags the deepest dirs as truncated", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/b"] = {},
			["a/b/c"] = {},
			["a/b/c/deep.txt"] = "",
		})
		local lines, snap = scan_dir_snap(tmpdir, { maxdepth = 2 })
		assert.same({ "a/", "  b/" }, lines)
		assert.is_true(snapshot.truncated_paths(snap)[tmpdir .. "/a/b"])
	end)

	------------------------------------------------------------------
	-- Ordering
	------------------------------------------------------------------

	it("sorts dirs, then links, then files with sort_method type", function()
		helpers.populate_dir(tmpdir, { ["zfile.txt"] = "", ["adir"] = {} })
		vim.loop.fs_symlink(tmpdir .. "/zfile.txt", tmpdir .. "/mlink")
		config.sort_method = "type"
		assert.same({ "adir/", "mlink@", "zfile.txt" }, scan_dir(tmpdir))
	end)

	it("sorts case-insensitively by name with sort_method name", function()
		helpers.populate_dir(tmpdir, { ["Beta.txt"] = "", ["alpha.txt"] = "", ["Gamma.txt"] = "" })
		config.sort_method = "name"
		assert.same({ "alpha.txt", "Beta.txt", "Gamma.txt" }, scan_dir(tmpdir))
	end)

	it("sorts siblings at every level, keeping subtrees together", function()
		helpers.populate_dir(tmpdir, {
			["zzz"] = {},
			["zzz/b.txt"] = "",
			["zzz/a.txt"] = "",
			["aaa"] = {},
			["aaa/c.txt"] = "",
		})
		config.sort_method = "name"
		assert.same({ "aaa/", "  c.txt", "zzz/", "  a.txt", "  b.txt" }, scan_dir(tmpdir))
	end)

	------------------------------------------------------------------
	-- scan_dir_children: exactly one level, for lazy expansion
	------------------------------------------------------------------

	it("scan_dir_children loads exactly one level", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/b"] = {},
			["a/b/deep.txt"] = "",
			["a/file.txt"] = "",
		})
		local children = scan.scan_dir_children(tmpdir .. "/a", tmpdir)
		local map = by_name(children)
		assert.equals(2, #children)
		assert.is_not_nil(map["b"])
		assert.is_not_nil(map["file.txt"])
		assert.is_nil(map["deep.txt"])
	end)

	it("scan_dir_children marks dirs lazy and leaves files unmarked", function()
		helpers.populate_dir(tmpdir, { ["a"] = {}, ["a/sub"] = {}, ["a/f.txt"] = "" })
		local map = by_name(scan.scan_dir_children(tmpdir .. "/a", tmpdir))
		assert.is_true(map["sub"].lazy)
		assert.is_nil(map["f.txt"].lazy)
	end)

	it("scan_dir_children gives absolute paths and no indent", function()
		helpers.populate_dir(tmpdir, { ["a"] = {}, ["a/f.txt"] = "" })
		local map = by_name(scan.scan_dir_children(tmpdir .. "/a", tmpdir))
		assert.equals(tmpdir .. "/a/f.txt", map["f.txt"].path)
		assert.is_nil(map["f.txt"].indent)
	end)

	it("scan_dir_children returns an empty list for an empty or missing dir", function()
		helpers.populate_dir(tmpdir, { ["empty"] = {} })
		assert.same({}, scan.scan_dir_children(tmpdir .. "/empty", tmpdir))
		assert.same({}, scan.scan_dir_children(tmpdir .. "/nope", tmpdir))
	end)

	------------------------------------------------------------------
	-- scan_disk_entries: the :w diff baseline
	------------------------------------------------------------------

	it("scan_disk_entries lists the tree with paths and types", function()
		helpers.populate_dir(tmpdir, { ["d"] = {}, ["d/f.txt"] = "", ["top.txt"] = "" })
		local map = {}
		for _, e in ipairs(scan.scan_disk_entries(tmpdir)) do
			map[e.path] = e.type
		end
		assert.equals("dir", map[tmpdir .. "/d"])
		assert.equals("file", map[tmpdir .. "/d/f.txt"])
		assert.equals("file", map[tmpdir .. "/top.txt"])
	end)

	it("scan_disk_entries applies the same visibility filter as the display", function()
		-- Otherwise a hidden file absent from the buffer would look like a
		-- deletion the user asked for.
		helpers.populate_dir(tmpdir, { [".secret"] = "", ["shown.txt"] = "" })
		config.show_hidden = false
		local paths = {}
		for _, e in ipairs(scan.scan_disk_entries(tmpdir)) do
			paths[e.path] = true
		end
		assert.is_nil(paths[tmpdir .. "/.secret"])
		assert.is_true(paths[tmpdir .. "/shown.txt"])
	end)
end)
