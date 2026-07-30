----------------------------------------------------------------------
-- Integration tests — the `/` fallback search.
--
-- Native `/` can only match entries already on screen, so filebuf falls back
-- to querying the whole tree and revealing just the ancestor chain of each
-- hit.  CI runs the suite both with and without fd installed, so these tests
-- stick to plain-substring patterns that both the fd and find(1) backends
-- handle identically, and assert on revealed paths rather than on engine
-- behaviour.
----------------------------------------------------------------------
local helpers = require("tests.helpers")
local search = require("filebuf.search")
local config = require("filebuf.config")

--- Sorted list of the paths in a match set, for stable assertions.
local function match_paths(buf)
	local paths = {}
	for path in pairs((helpers.state(buf).matches or {})) do
		paths[#paths + 1] = path
	end
	table.sort(paths)
	return paths
end

--- Locate a display entry by absolute path.
local function entry_at(buf, path)
	for _, e in ipairs(helpers.display_entries(buf)) do
		if e.path == path then
			return e
		end
	end
	return nil
end

describe("search", function()
	local tmpdir
	local buf

	before_each(function()
		tmpdir = helpers.create_temp_dir()
		config.show_hidden = false
	end)

	after_each(function()
		helpers.close_filebuf(buf)
		helpers.cleanup_dir(tmpdir)
		config.show_hidden = false
	end)

	------------------------------------------------------------------
	-- query
	------------------------------------------------------------------

	it("query finds a deeply nested file", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/b"] = {},
			["a/b/c"] = {},
			["a/b/c/needle.txt"] = "",
			["a/b/c/other.txt"] = "",
		})
		local paths = search.query(tmpdir, "needle")
		assert.same({ tmpdir .. "/a/b/c/needle.txt" }, paths)
	end)

	it("query returns nothing for a pattern with no hits", function()
		helpers.populate_dir(tmpdir, { ["a"] = {}, ["a/file.txt"] = "" })
		assert.same({}, search.query(tmpdir, "nothing_matches_this"))
	end)

	it("query returns nothing for an empty pattern", function()
		helpers.populate_dir(tmpdir, { ["file.txt"] = "" })
		assert.same({}, search.query(tmpdir, ""))
	end)

	it("query skips hits under a hidden directory when show_hidden is off", function()
		helpers.populate_dir(tmpdir, {
			[".secret"] = {},
			[".secret/needle.txt"] = "",
			["open"] = {},
			["open/needle.txt"] = "",
		})
		assert.same({ tmpdir .. "/open/needle.txt" }, search.query(tmpdir, "needle"))
	end)

	it("query includes hits under a hidden directory when show_hidden is on", function()
		helpers.populate_dir(tmpdir, {
			[".secret"] = {},
			[".secret/needle.txt"] = "",
		})
		config.show_hidden = true
		assert.same({ tmpdir .. "/.secret/needle.txt" }, search.query(tmpdir, "needle"))
	end)

	------------------------------------------------------------------
	-- run: reveal + highlight + cursor
	------------------------------------------------------------------

	it("run finds and highlights a deeply nested hit", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/b"] = {},
			["a/b/c"] = {},
			["a/b/c/needle.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		-- With eager loading the full tree is already on screen; search.run
		-- finds the hit among them and records it in the match set.
		assert.equals(1, search.run(buf, "needle"))
		assert.same({ "a/", "  b/", "    c/", "      needle.txt" }, helpers.get_buffer_lines(buf))
		assert.same({ tmpdir .. "/a/b/c/needle.txt" }, match_paths(buf))
	end)

	it("run parks the cursor on the first match", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/needle.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		search.run(buf, "needle")
		local lnum = vim.api.nvim_win_get_cursor(0)[1]
		assert.equals("  needle.txt", helpers.get_buffer_lines(buf)[lnum])
	end)

	it("run does not alter lines outside the ancestor chain of a hit", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/b"] = {},
			["a/b/needle.txt"] = "",
			["a/sibling"] = {},
			["a/sibling/untouched.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		local before = helpers.get_buffer_lines(buf)
		assert.is_not_nil(entry_at(buf, tmpdir .. "/a/sibling"))
		assert.is_not_nil(entry_at(buf, tmpdir .. "/a/sibling/untouched.txt"))

		search.run(buf, "needle")
		-- Finding needle.txt must not change unrelated buffer lines.
		assert.same(before, helpers.get_buffer_lines(buf))
		assert.same({ tmpdir .. "/a/b/needle.txt" }, match_paths(buf))
	end)

	it("run matches hits across several different subtrees", function()
		helpers.populate_dir(tmpdir, {
			["alpha"] = {},
			["alpha/deep"] = {},
			["alpha/deep/needle.txt"] = "",
			["zulu"] = {},
			["zulu/needle.txt"] = "",
			["unrelated"] = {},
			["unrelated/other.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		assert.equals(2, search.run(buf, "needle"))
		assert.same({
			tmpdir .. "/alpha/deep/needle.txt",
			tmpdir .. "/zulu/needle.txt",
		}, match_paths(buf))
		-- The unrelated entry is still there — it was never removed.
		assert.is_not_nil(entry_at(buf, tmpdir .. "/unrelated/other.txt"))
	end)

	it("run leaves the buffer untouched when there are no hits", function()
		helpers.populate_dir(tmpdir, { ["a"] = {}, ["a/file.txt"] = "" })
		buf = helpers.open_filebuf(tmpdir)
		local before = helpers.get_buffer_lines(buf)

		assert.equals(0, search.run(buf, "nothing_matches_this"))
		assert.same(before, helpers.get_buffer_lines(buf))
		assert.same({}, match_paths(buf))
	end)

	it("run warns only when nothing matched on screen either", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/file.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)

		local warnings = {}
		local real_notify = vim.notify
		vim.notify = function(msg, level)
			if level == vim.log.levels.WARN then
				warnings[#warnings + 1] = msg
			end
		end
		local ok, err = pcall(function()
			-- Nothing on screen, nothing on disk → the user should hear about it.
			search.run(buf, "nothing_matches_this")
			assert.equals(1, #warnings)
			assert.is_true(warnings[1]:find("pattern not found", 1, true) ~= nil)

			-- "^a" matches the buffer line "a/" but no basename, so fd/find
			-- return nothing.  That is not a failure worth reporting.
			warnings = {}
			search.run(buf, "^a")
			assert.same({}, warnings)
		end)
		vim.notify = real_notify
		assert.is_true(ok, tostring(err))
	end)

	it("run matches directories too", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/needledir"] = {},
			["a/needledir/inside.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		assert.equals(1, search.run(buf, "needledir"))
		assert.same({ tmpdir .. "/a/needledir" }, match_paths(buf))
		-- The directory itself is the match — its contents are still present.
		assert.is_not_nil(entry_at(buf, tmpdir .. "/a/needledir/inside.txt"))
	end)

	it("run queries the disk even when the pattern already matches on screen", function()
		-- A hit in the buffer says nothing about how many more are unloaded.
		helpers.populate_dir(tmpdir, {
			["needle.txt"] = "",
			["a"] = {},
			["a/needle.txt"] = "",
			["a/b"] = {},
			["a/b/needle.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		-- The top-level hit is already visible before searching.
		assert.is_true(helpers.line_set(buf)["needle.txt"])

		assert.equals(3, search.run(buf, "needle"))
		assert.same({
			tmpdir .. "/a/b/needle.txt",
			tmpdir .. "/a/needle.txt",
			tmpdir .. "/needle.txt",
		}, match_paths(buf))
	end)

	it("run keeps the cursor when it already sits on a match", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/needle.txt"] = "",
			["zzz_needle.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		-- Put the cursor on the already-visible top-level hit, mimicking what
		-- the native search does before the fallback runs.
		assert.is_not_nil(helpers.reveal(buf, tmpdir .. "/zzz_needle.txt"))
		for _, e in ipairs(helpers.display_entries(buf)) do
			if e.name == "zzz_needle.txt" then
				vim.api.nvim_win_set_cursor(0, { e.lnum, 0 })
			end
		end

		search.run(buf, "needle")
		local lnum = vim.api.nvim_win_get_cursor(0)[1]
		-- Still on zzz_needle.txt, not yanked back to the topmost match.
		assert.equals("zzz_needle.txt", helpers.get_buffer_lines(buf)[lnum])
	end)

	it("run moves to the topmost match when the cursor is not on one", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/needle.txt"] = "",
			["b"] = {},
			["b/needle.txt"] = "",
			["zzz_other.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		local lines = helpers.get_buffer_lines(buf)
		vim.api.nvim_win_set_cursor(0, { #lines, 0 }) -- on zzz_other.txt

		search.run(buf, "needle")
		local lnum = vim.api.nvim_win_get_cursor(0)[1]
		assert.equals("  needle.txt", helpers.get_buffer_lines(buf)[lnum])
		-- Topmost of the two, i.e. the one under "a".
		assert.equals("a/", helpers.get_buffer_lines(buf)[lnum - 1])
	end)

	it("run replaces the previous match set", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/first.txt"] = "",
			["a/second.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		search.run(buf, "first")
		assert.same({ tmpdir .. "/a/first.txt" }, match_paths(buf))
		search.run(buf, "second")
		assert.same({ tmpdir .. "/a/second.txt" }, match_paths(buf))
	end)

	it("run does not mark the buffer modified", function()
		helpers.populate_dir(tmpdir, { ["a"] = {}, ["a/needle.txt"] = "" })
		buf = helpers.open_filebuf(tmpdir)
		search.run(buf, "needle")
		assert.is_false(vim.bo[buf].modified)
	end)

	it("run skips hits inside hidden dirs when show_hidden is off", function()
		helpers.populate_dir(tmpdir, {
			[".secret"] = {},
			[".secret/needle.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		assert.equals(0, search.run(buf, "needle"))
		assert.same({}, match_paths(buf))
	end)

	it("run reveals hits inside hidden dirs when show_hidden is on", function()
		helpers.populate_dir(tmpdir, {
			[".secret"] = {},
			[".secret/needle.txt"] = "",
		})
		config.show_hidden = true
		buf = helpers.open_filebuf(tmpdir)
		assert.equals(1, search.run(buf, "needle"))
		assert.same({ tmpdir .. "/.secret/needle.txt" }, match_paths(buf))
	end)

	------------------------------------------------------------------
	-- clear
	------------------------------------------------------------------

	it("clear drops the match set", function()
		helpers.populate_dir(tmpdir, { ["a"] = {}, ["a/needle.txt"] = "" })
		buf = helpers.open_filebuf(tmpdir)
		search.run(buf, "needle")
		assert.equals(1, #match_paths(buf))

		search.clear(buf)
		assert.is_nil(helpers.state(buf).matches)
	end)

	it("a save clears the match set (lnums are invalidated)", function()
		helpers.populate_dir(tmpdir, { ["a"] = {}, ["a/needle.txt"] = "" })
		buf = helpers.open_filebuf(tmpdir)
		search.run(buf, "needle")
		assert.equals(1, #match_paths(buf))

		helpers.save_buffer(buf)
		assert.same({}, match_paths(buf))
	end)

	------------------------------------------------------------------
	-- :FilebufFind
	------------------------------------------------------------------

	it(":FilebufFind reveals a match", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/b"] = {},
			["a/b/needle.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		vim.cmd("FilebufFind needle")
		assert.same({ "a/", "  b/", "    needle.txt" }, helpers.get_buffer_lines(buf))
		assert.same({ tmpdir .. "/a/b/needle.txt" }, match_paths(buf))
	end)
end)
