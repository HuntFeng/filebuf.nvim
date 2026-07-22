----------------------------------------------------------------------
-- Integration tests — buffer rendering / display.
-- Verifies that filebuf correctly renders directory trees into the buffer.
----------------------------------------------------------------------
local helpers = require("tests.helpers")

describe("display", function()
	local tmpdir
	local buf

	before_each(function()
		tmpdir = helpers.create_temp_dir()
	end)

	after_each(function()
		helpers.close_filebuf(buf)
		helpers.cleanup_dir(tmpdir)
	end)

	it("renders files without suffix", function()
		helpers.populate_dir(tmpdir, {
			["hello.txt"] = "",
			["world.md"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		local lines = helpers.get_buffer_lines(buf)
		-- Both are root-level files; no trailing / or @.
		assert.equals("hello.txt", lines[1])
		assert.equals("world.md", lines[2])
	end)

	it("renders directories with trailing /", function()
		helpers.populate_dir(tmpdir, {
			["mydir"] = {},
		})
		buf = helpers.open_filebuf(tmpdir)
		local lines = helpers.get_buffer_lines(buf)
		assert.equals("mydir/", lines[1])
	end)

	it("renders nested files with correct indent", function()
		helpers.populate_dir(tmpdir, {
			["parent"] = {},
			["parent/child.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		local lines = helpers.get_buffer_lines(buf)
		-- shiftwidth=2: parent at indent 0, child at indent 1 (2 spaces).
		assert.equals("parent/", lines[1])
		assert.equals("  child.txt", lines[2])
	end)

	it("renders deeply nested structures with increasing indent", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/b"] = {},
			["a/b/c"] = {},
			["a/b/c/deep.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		local lines = helpers.get_buffer_lines(buf)
		assert.equals("a/", lines[1])
		assert.equals("  b/", lines[2])
		assert.equals("    c/", lines[3])
		assert.equals("      deep.txt", lines[4])
	end)

	it("shows directories before files (sorted)", function()
		helpers.populate_dir(tmpdir, {
			["zebra.txt"] = "",
			["aardvark"] = {},
			["monkey.txt"] = "",
			["beta"] = {},
		})
		buf = helpers.open_filebuf(tmpdir)
		local lines = helpers.get_buffer_lines(buf)
		-- Dirs come first, alphabetically; then files, alphabetically.
		assert.equals("aardvark/", lines[1])
		assert.equals("beta/", lines[2])
		assert.equals("monkey.txt", lines[3])
		assert.equals("zebra.txt", lines[4])
	end)

	it("handles an empty directory (no lines)", function()
		buf = helpers.open_filebuf(tmpdir)
		local lines = helpers.get_buffer_lines(buf)
		-- Empty dir produces no entries, so buffer should have 0 or 1 empty line.
		assert.is_true(#lines == 0 or (#lines == 1 and lines[1] == ""))
	end)

	it("sets the buffer as not modified after opening", function()
		helpers.populate_dir(tmpdir, { ["a.txt"] = "" })
		buf = helpers.open_filebuf(tmpdir)
		assert.is_false(vim.bo[buf].modified)
	end)
end)
