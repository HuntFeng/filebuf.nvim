----------------------------------------------------------------------
-- Integration tests — yank / paste (copy).
-- gy marks an entry, gp inserts a bound line, :w performs the real copy.
----------------------------------------------------------------------
local helpers = require("tests.helpers")

describe("copy", function()
	local tmpdir
	local buf

	--- Move the cursor to the line whose text is exactly `text`.
	local function goto_line(text)
		for i, line in ipairs(helpers.get_buffer_lines(buf)) do
			if line == text then
				vim.api.nvim_win_set_cursor(0, { i, 0 })
				return i
			end
		end
		error("line not found in buffer: " .. vim.inspect(text))
	end

	--- Replace the text of the line at `lnum`.
	local function set_line(lnum, text)
		vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { text })
	end

	before_each(function()
		tmpdir = helpers.create_temp_dir()
		helpers.populate_dir(tmpdir, {
			["source.txt"] = "payload",
			["other.txt"] = "other",
			["dest"] = {},
			["tree"] = {},
			["tree/child.txt"] = "child",
			["tree/deep"] = {},
			["tree/deep/leaf.txt"] = "leaf",
		})
		buf = helpers.open_filebuf(tmpdir)
	end)

	after_each(function()
		helpers.close_filebuf(buf)
		helpers.cleanup_dir(tmpdir)
	end)

	it("copies a file into another directory", function()
		goto_line("source.txt")
		require("filebuf.copy").yank_at_cursor(buf)

		goto_line("dest/")
		require("filebuf.copy").paste(buf)

		helpers.save_buffer(buf)

		assert.equals("file", helpers.fs_type(tmpdir .. "/dest/source.txt"))
		assert.equals("payload", helpers.read_file(tmpdir .. "/dest/source.txt"))
		-- The source is untouched.
		assert.equals("payload", helpers.read_file(tmpdir .. "/source.txt"))
	end)

	it("copies a directory and its whole subtree", function()
		goto_line("tree/")
		require("filebuf.copy").yank_at_cursor(buf)

		goto_line("dest/")
		require("filebuf.copy").paste(buf)

		helpers.save_buffer(buf)

		assert.equals("directory", helpers.fs_type(tmpdir .. "/dest/tree"))
		assert.equals("child", helpers.read_file(tmpdir .. "/dest/tree/child.txt"))
		assert.equals("directory", helpers.fs_type(tmpdir .. "/dest/tree/deep"))
		assert.equals("leaf", helpers.read_file(tmpdir .. "/dest/tree/deep/leaf.txt"))
		-- The original subtree survives.
		assert.equals("leaf", helpers.read_file(tmpdir .. "/tree/deep/leaf.txt"))
	end)

	it("copies under a new name when the pasted line is renamed", function()
		goto_line("source.txt")
		require("filebuf.copy").yank_at_cursor(buf)

		-- Paste in place, then rename — the only way to duplicate within one
		-- directory, and the case a name-matching implementation would miss.
		local at = goto_line("source.txt")
		require("filebuf.copy").paste(buf)
		set_line(at + 1, "copy.txt")

		helpers.save_buffer(buf)

		assert.equals("payload", helpers.read_file(tmpdir .. "/copy.txt"))
		assert.equals("payload", helpers.read_file(tmpdir .. "/source.txt"))
	end)

	it("does not turn a copy into a move when a same-named entry is deleted", function()
		-- other.txt disappears from the buffer while a copy of source.txt lands
		-- in dest/.  Name-based rename matching must not pair the two.
		goto_line("source.txt")
		require("filebuf.copy").yank_at_cursor(buf)

		goto_line("dest/")
		require("filebuf.copy").paste(buf)
		local other = goto_line("other.txt")
		vim.api.nvim_buf_set_lines(buf, other - 1, other, false, {})

		helpers.save_buffer(buf)

		assert.equals("payload", helpers.read_file(tmpdir .. "/dest/source.txt"))
		assert.equals("payload", helpers.read_file(tmpdir .. "/source.txt"))
	end)

	it("yanks a visual range and pastes every entry", function()
		goto_line("source.txt")
		local first = goto_line("source.txt")
		local second = goto_line("other.txt")
		require("filebuf.copy").yank(buf, math.min(first, second), math.max(first, second))

		goto_line("dest/")
		require("filebuf.copy").paste(buf)

		helpers.save_buffer(buf)

		assert.equals("payload", helpers.read_file(tmpdir .. "/dest/source.txt"))
		assert.equals("other", helpers.read_file(tmpdir .. "/dest/other.txt"))
	end)

	it("drops entries nested under a yanked directory", function()
		local tree = goto_line("tree/")
		require("filebuf.copy").yank(buf, tree, tree + 3)

		local clip = helpers.state(buf).clipboard
		assert.equals(1, #clip)
		assert.equals(tmpdir .. "/tree", clip[1].path)
	end)

	it("marks the children of a yanked directory as copied", function()
		goto_line("tree/")
		local copy = require("filebuf.copy")
		copy.yank_at_cursor(buf)

		local st = helpers.state(buf)
		assert.is_true(copy.is_marked(st, tmpdir .. "/tree"))
		assert.is_true(copy.is_marked(st, tmpdir .. "/tree/deep/leaf.txt"))
		assert.is_false(copy.is_marked(st, tmpdir .. "/source.txt"))
	end)

	it("clears the clipboard after a successful save", function()
		goto_line("source.txt")
		require("filebuf.copy").yank_at_cursor(buf)
		goto_line("dest/")
		require("filebuf.copy").paste(buf)

		helpers.save_buffer(buf)

		local st = helpers.state(buf)
		assert.is_nil(st.clipboard)
		assert.is_nil(st.copy_targets)
	end)

	it("refuses to save a paste that duplicates a sibling name", function()
		goto_line("source.txt")
		require("filebuf.copy").yank_at_cursor(buf)
		goto_line("source.txt")
		require("filebuf.copy").paste(buf)

		helpers.save_buffer(buf)

		local diags = helpers.get_diagnostics(buf)
		assert.is_true(#diags > 0)
		-- Nothing was written: the yank is still pending and the tree is intact.
		assert.is_not_nil(helpers.state(buf).clipboard)
		assert.is_nil(helpers.fs_stat(tmpdir .. "/dest/source.txt"))
		assert.equals("payload", helpers.read_file(tmpdir .. "/source.txt"))
	end)

	it("reports an error when the yanked source is gone", function()
		goto_line("source.txt")
		require("filebuf.copy").yank_at_cursor(buf)
		goto_line("dest/")
		require("filebuf.copy").paste(buf)

		vim.loop.fs_unlink(tmpdir .. "/source.txt")
		helpers.save_buffer(buf)

		assert.is_true(#helpers.get_diagnostics(buf) > 0)
		assert.is_nil(helpers.fs_stat(tmpdir .. "/dest/source.txt"))
	end)

	--- Send keys through the real mappings.
	local function feed(keys)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
	end

	it("copies through the gy / gp keymaps", function()
		goto_line("source.txt")
		feed("gy")
		goto_line("dest/")
		feed("gp")

		helpers.save_buffer(buf)

		assert.equals("payload", helpers.read_file(tmpdir .. "/dest/source.txt"))
	end)

	it("keeps the copy binding when the pasted line is retyped with cc", function()
		goto_line("source.txt")
		feed("gy")
		feed("gp")
		feed("ccrenamed.txt")

		helpers.save_buffer(buf)

		assert.equals("payload", helpers.read_file(tmpdir .. "/renamed.txt"))
		assert.equals("payload", helpers.read_file(tmpdir .. "/source.txt"))
	end)

	it("yanks a visual selection through the x-mode gy mapping", function()
		goto_line("other.txt")
		feed("Vjgy")
		goto_line("dest/")
		feed("gp")

		helpers.save_buffer(buf)

		assert.equals("other", helpers.read_file(tmpdir .. "/dest/other.txt"))
		assert.equals("payload", helpers.read_file(tmpdir .. "/dest/source.txt"))
	end)

	it("pasting with an empty clipboard is a no-op", function()
		local before = helpers.get_buffer_lines(buf)
		goto_line("dest/")
		require("filebuf.copy").paste(buf)
		assert.same(before, helpers.get_buffer_lines(buf))
	end)
end)
