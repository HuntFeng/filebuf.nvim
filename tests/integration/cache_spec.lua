----------------------------------------------------------------------
-- Integration tests — the row cache as observed through the plugin.
--
-- These assert the properties the cache exists for, rather than its innards
-- (tests/unit/snapshot_spec.lua covers those):
--
--   * re-projections -- toggling hidden entries, changing sort method,
--     refreshing after a save -- must not run find(1) again;
--   * a :w with nothing edited must not touch the disk at all;
--   * every snapshot-backed lookup must agree with the buffer-walking
--     fallback, because the fallback is what runs the moment the buffer is
--     edited.  That last one is the invariant the whole design rests on: if
--     the two disagree, a path resolves to the wrong file.
----------------------------------------------------------------------
local helpers = require("tests.helpers")
local state = require("filebuf.state")
local render = require("filebuf.render")
local scan = require("filebuf.scan")
local sync = require("filebuf.sync")
local config = require("filebuf.config")

describe("row cache", function()
	local tmpdir, buf

	before_each(function()
		tmpdir = helpers.create_temp_dir()
		config.sort_method = "type"
		config.show_hidden = false
		helpers.populate_dir(tmpdir, {
			["src"] = {},
			["src/nested"] = {},
			["src/nested/deep.lua"] = "",
			["src/main.lua"] = "",
			["docs"] = {},
			["docs/guide.md"] = "",
			[".hidden"] = {},
			[".hidden/inside.txt"] = "",
			[".dotfile"] = "",
			["zeta.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
	end)

	after_each(function()
		helpers.close_filebuf(buf)
		helpers.cleanup_dir(tmpdir)
		config.show_hidden = false
		config.sort_method = "type"
	end)

	------------------------------------------------------------------
	-- The cache exists and tracks whether it still describes the buffer
	------------------------------------------------------------------

	it("populates the cache on open and marks it clean", function()
		local st = helpers.state(buf)
		assert.is_not_nil(st.snap)
		assert.is_true(st.snap_clean)
		assert.equals(#helpers.get_buffer_lines(buf), #st.snap.view)
	end)

	it("caches hidden rows that are not displayed", function()
		local snap = helpers.snapshot(buf)
		-- More rows held than lines shown, because the hidden ones are retained.
		assert.is_true(snap.n > #snap.view)
	end)

	it("marks the cache stale on the first edit and records the dirty range", function()
		local st = helpers.state(buf)
		vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "brand_new.txt" })
		assert.is_false(st.snap_clean)
		assert.equals(1, st.dirty_lo)
	end)

	it("marks the cache clean again after a re-render", function()
		local st = helpers.state(buf)
		vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "brand_new.txt" })
		assert.is_false(st.snap_clean)
		render.tree(buf)
		assert.is_true(st.snap_clean)
		assert.is_nil(st.dirty_lo)
	end)

	it("frees the cache when the buffer goes away", function()
		helpers.close_filebuf(buf)
		assert.is_nil(state.get(buf))
	end)

	------------------------------------------------------------------
	-- Re-projections must not hit the disk
	------------------------------------------------------------------

	it("toggles hidden entries without scanning again", function()
		local scans = helpers.count_scans(function()
			vim.cmd("FilebufToggleHidden")
			vim.cmd("FilebufToggleHidden")
			vim.cmd("FilebufToggleHidden")
		end)
		assert.equals(0, scans)
	end)

	it("shows and hides the same entries across a toggle round-trip", function()
		local before = helpers.get_buffer_lines(buf)
		vim.cmd("FilebufToggleHidden")
		assert.is_true(helpers.line_set(buf)[".dotfile"])
		vim.cmd("FilebufToggleHidden")
		assert.same(before, helpers.get_buffer_lines(buf))
	end)

	it("changes sort method without scanning again", function()
		local scans = helpers.count_scans(function()
			vim.cmd("FilebufSortMethod name")
			vim.cmd("FilebufSortMethod type")
		end)
		assert.equals(0, scans)
	end)

	it("re-orders on sort method change", function()
		vim.cmd("FilebufSortMethod name")
		local lines = helpers.get_buffer_lines(buf)
		-- Sorting purely by name puts main.lua before nested/ inside src/.
		local main_at, nested_at
		for i, l in ipairs(lines) do
			if l:match("main%.lua$") then
				main_at = i
			elseif l:match("nested/$") then
				nested_at = i
			end
		end
		assert.is_not_nil(main_at)
		assert.is_not_nil(nested_at)
		assert.is_true(main_at < nested_at)
	end)

	it("declines to re-project over unsaved edits", function()
		vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "unsaved.txt" })
		assert.is_false(render.reproject(buf, { show_hidden = true }))
		-- The edit survives.
		assert.equals("unsaved.txt", helpers.get_buffer_lines(buf)[1])
	end)

	it("refuses to toggle while the buffer is modified", function()
		vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "unsaved.txt" })
		vim.cmd("FilebufToggleHidden")
		assert.equals("unsaved.txt", helpers.get_buffer_lines(buf)[1])
	end)

	------------------------------------------------------------------
	-- show_hidden is per root, not global
	------------------------------------------------------------------

	it("does not mutate the global config when toggling", function()
		vim.cmd("FilebufToggleHidden")
		assert.is_false(config.show_hidden)
		assert.is_true(helpers.state(buf).show_hidden)
	end)

	it("restores a root's toggle when it is reopened", function()
		vim.cmd("FilebufToggleHidden")
		assert.is_true(helpers.state(buf).show_hidden)
		local other = helpers.create_temp_dir()
		helpers.populate_dir(other, { ["only.txt"] = "" })
		buf = helpers.open_filebuf(other)
		assert.is_false(helpers.state(buf).show_hidden, "a different root uses the configured default")
		buf = helpers.open_filebuf(tmpdir)
		assert.is_true(helpers.state(buf).show_hidden, "the original root remembers")
		helpers.cleanup_dir(other)
	end)

	------------------------------------------------------------------
	-- :w short-circuit
	------------------------------------------------------------------

	it("does no disk work on :w when nothing was edited", function()
		local baseline_scans, diffs = 0, 0
		local real_disk, real_diff = scan.scan_disk_entries, sync.compute_diff
		scan.scan_disk_entries = function(...)
			baseline_scans = baseline_scans + 1
			return real_disk(...)
		end
		sync.compute_diff = function(...)
			diffs = diffs + 1
			return real_diff(...)
		end
		helpers.save_buffer(buf)
		scan.scan_disk_entries, sync.compute_diff = real_disk, real_diff

		assert.equals(0, baseline_scans)
		assert.equals(0, diffs)
	end)

	it("still diffs and applies when something was edited", function()
		local baseline_scans = 0
		local real_disk = scan.scan_disk_entries
		scan.scan_disk_entries = function(...)
			baseline_scans = baseline_scans + 1
			return real_disk(...)
		end
		vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "created_by_test.txt" })
		helpers.save_buffer(buf)
		scan.scan_disk_entries = real_disk

		assert.equals(1, baseline_scans)
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/created_by_test.txt"))
	end)

	it("refreshes from the applied ops instead of rescanning after a save", function()
		vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "post_save.txt" })
		local scans = helpers.count_scans(function()
			helpers.save_buffer(buf)
		end)
		-- The post-save re-render is a re-projection of the mutated rows.
		assert.equals(0, scans)
		assert.is_true(helpers.line_set(buf)["post_save.txt"])
	end)

	it("leaves the cache describing the tree after a save", function()
		vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "after.txt" })
		helpers.save_buffer(buf)
		local st = helpers.state(buf)
		assert.is_true(st.snap_clean)
		-- What the cache projects is what a completely fresh scan would produce.
		local fresh = require("filebuf.snapshot").new(tmpdir)
		local fresh_lines = scan.scan_into(fresh, tmpdir, { show_hidden = st.show_hidden })
		assert.same(fresh_lines, helpers.get_buffer_lines(buf))
	end)

	------------------------------------------------------------------
	-- Cache and fallback must agree.  This is the load-bearing invariant.
	------------------------------------------------------------------

	--- Run `fn` with the snapshot fast paths disabled.
	local function with_fallback(st, fn)
		local saved = st.snap_clean
		st.snap_clean = false
		st._by_path_dirty = true
		local ok, res = pcall(fn)
		st.snap_clean = saved
		if not ok then
			error(res)
		end
		return res
	end

	it("resolves every line to the same entry via the cache and the fallback", function()
		local st = helpers.state(buf)
		for lnum = 1, vim.api.nvim_buf_line_count(buf) do
			local cached = state.resolve_entry(buf, lnum)
			local walked = with_fallback(st, function()
				return state.resolve_entry(buf, lnum)
			end)
			assert.is_not_nil(cached, "line " .. lnum .. " unresolved via cache")
			assert.equals(walked.path, cached.path, "path mismatch on line " .. lnum)
			assert.equals(walked.type, cached.type, "type mismatch on line " .. lnum)
			assert.equals(walked.indent, cached.indent, "indent mismatch on line " .. lnum)
		end
	end)

	it("maps every path back to the same line via the cache and the fallback", function()
		local st = helpers.state(buf)
		for lnum = 1, vim.api.nvim_buf_line_count(buf) do
			local entry = state.resolve_entry(buf, lnum)
			assert.equals(lnum, state.lnum_of(buf, entry.path))
			local walked = with_fallback(st, function()
				return state.lnum_of(buf, entry.path)
			end)
			assert.equals(lnum, walked, "fallback disagreed for " .. entry.path)
		end
	end)

	it("computes the same fold level via the cache and the fallback", function()
		local st = helpers.state(buf)
		vim.api.nvim_set_current_buf(buf)
		for lnum = 1, vim.api.nvim_buf_line_count(buf) do
			vim.v.lnum = lnum
			local cached = _G.FilebufFoldExpr()
			local walked = with_fallback(st, function()
				vim.v.lnum = lnum
				return _G.FilebufFoldExpr()
			end)
			assert.equals(walked, cached, "fold level mismatch on line " .. lnum)
		end
	end)

	it("agrees with the fallback after a toggle changes the projection", function()
		local st = helpers.state(buf)
		vim.cmd("FilebufToggleHidden")
		for lnum = 1, vim.api.nvim_buf_line_count(buf) do
			local cached = state.resolve_entry(buf, lnum)
			local walked = with_fallback(st, function()
				return state.resolve_entry(buf, lnum)
			end)
			assert.equals(walked.path, cached.path, "path mismatch on line " .. lnum)
		end
	end)

	it("keeps resolving correctly once the buffer is edited", function()
		-- After an edit the cache is stale by definition, so every lookup goes
		-- through the buffer walk; it still has to be right.
		vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "edited.txt" })
		assert.is_false(helpers.state(buf).snap_clean)
		local entry = state.resolve_entry(buf, 1)
		assert.equals(tmpdir .. "/edited.txt", entry.path)
		assert.equals("file", entry.type)
	end)
end)
