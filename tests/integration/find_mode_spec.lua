----------------------------------------------------------------------
-- Integration tests — async find mode (g/).
----------------------------------------------------------------------
local helpers = require("tests.helpers")
local config = require("filebuf.config")
local find = require("filebuf.find")

describe("find mode", function()
	local tmpdir
	local buf

	before_each(function()
		tmpdir = helpers.create_temp_dir()
		config.show_hidden = false
		config.respect_ignore = false
	end)

	after_each(function()
		helpers.close_filebuf(buf)
		helpers.cleanup_dir(tmpdir)
		config.show_hidden = false
		config.respect_ignore = false
	end)

	it("enters find mode and sets the mode flag", function()
		helpers.populate_dir(tmpdir, {
			["file1.txt"] = "",
			["file2.lua"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)

		vim.fn.input = function()
			return "txt"
		end
		find.enter(buf)

		assert.equals("find", vim.b[buf].filebuf_mode, "should be in find mode")
	end)

	it("exits find mode with <Esc> and clears the mode flag", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/file.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		local original_lines = helpers.get_buffer_lines(buf)

		vim.fn.input = function()
			return "file"
		end
		find.enter(buf)
		assert.equals("find", vim.b[buf].filebuf_mode)

		find.exit(buf)
		assert.equals("normal", vim.b[buf].filebuf_mode, "mode should return to normal")
	end)

	it("restores the prior buffer view when exiting find mode", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/file1.txt"] = "",
			["b"] = {},
			["b/file2.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		local original_lines = helpers.get_buffer_lines(buf)

		vim.fn.input = function()
			return "file"
		end
		find.enter(buf)
		-- The async job is running; we don't wait for results before exiting.
		-- The important thing is that exit restores the snapshot.
		find.exit(buf)

		assert.same(original_lines, helpers.get_buffer_lines(buf), "should restore original view")
	end)

	it("scopes saves to the query tree when filebuf_query_entries is set", function()
		-- This test verifies the save-scoping logic in init.lua works correctly.
		-- We can't easily test the full async flow here, but we can verify that
		-- when filebuf_mode == "find" and filebuf_query_entries is set,
		-- the save diff uses only those entries.
		helpers.populate_dir(tmpdir, {
			["dir"] = {},
			["dir/inquery.txt"] = "",
			["dir/notinquery.lua"] = "should survive",
		})
		buf = helpers.open_filebuf(tmpdir)

		-- Manually set up a find-mode state (simulating what enter would do).
		vim.b[buf].filebuf_mode = "find"
		-- Simulate a query tree with only the .txt file.
		vim.b[buf].filebuf_query_entries = {
			{ name = "dir", type = "dir", path = tmpdir .. "/dir", indent = 0 },
			{ name = "inquery.txt", type = "file", path = tmpdir .. "/dir/inquery.txt", indent = 1 },
		}

		-- Render those entries.
		local lines = { "dir/", "  inquery.txt" }
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		-- Save (the diff will only see inquery.txt in the baseline).
		helpers.save_buffer(buf)

		-- notinquery.lua should still exist (not treated as deleted by the scoped diff).
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/dir/notinquery.lua"))
		assert.equals("should survive", helpers.read_file(tmpdir .. "/dir/notinquery.lua"))

		-- Clean up the mode state.
		vim.b[buf].filebuf_mode = "normal"
		vim.b[buf].filebuf_query_entries = nil
	end)

	it("cancels find mode entry if the user provides an empty pattern", function()
		helpers.populate_dir(tmpdir, { ["file.txt"] = "" })
		buf = helpers.open_filebuf(tmpdir)
		local original_lines = helpers.get_buffer_lines(buf)

		vim.fn.input = function()
			return ""
		end
		find.enter(buf)

		assert.equals("normal", vim.b[buf].filebuf_mode, "should stay in normal mode with empty pattern")
		assert.same(original_lines, helpers.get_buffer_lines(buf), "buffer should be unchanged")
	end)

	it("cleans up the session when the buffer is deleted", function()
		helpers.populate_dir(tmpdir, { ["file.txt"] = "" })
		buf = helpers.open_filebuf(tmpdir)

		vim.fn.input = function()
			return "txt"
		end
		find.enter(buf)
		assert.equals("find", vim.b[buf].filebuf_mode)

		-- Cleanup should be idempotent.
		find.cleanup(buf)
		assert.equals("normal", vim.b[buf].filebuf_mode)

		find.cleanup(buf) -- second call should not error
	end)
end)
