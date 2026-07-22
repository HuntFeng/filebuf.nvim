----------------------------------------------------------------------
-- Integration tests — file and directory renaming.
-- Verifies that editing entry names or moving entries (changing indent)
-- renames/moves them on disk after :w.
----------------------------------------------------------------------
local helpers = require("tests.helpers")

describe("rename", function()
	local tmpdir
	local buf

	before_each(function()
		tmpdir = helpers.create_temp_dir()
		helpers.populate_dir(tmpdir, {
			["oldname.txt"] = "content",
			["mydir"] = {},
			["mydir/nested.txt"] = "inside",
			["sourcedir"] = {},
			["sourcedir/move_me.txt"] = "movable",
		})
		buf = helpers.open_filebuf(tmpdir)
	end)

	after_each(function()
		helpers.close_filebuf(buf)
		helpers.cleanup_dir(tmpdir)
	end)

	it("renames a file when its name is edited in-place", function()
		local lines = helpers.get_buffer_lines(buf)
		-- Find the line with "oldname.txt" and replace it.
		for i, line in ipairs(lines) do
			if line == "oldname.txt" then
				lines[i] = "newname.txt"
				break
			end
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		helpers.save_buffer(buf)

		-- Old file is gone, new file exists with content preserved.
		assert.is_nil(helpers.fs_stat(tmpdir .. "/oldname.txt"))
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/newname.txt"))
		assert.equals("content", helpers.read_file(tmpdir .. "/newname.txt"))
	end)

	it("renames a directory when its name is edited", function()
		local lines = helpers.get_buffer_lines(buf)
		for i, line in ipairs(lines) do
			if line == "mydir/" then
				lines[i] = "renamed_dir/"
				break
			end
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		helpers.save_buffer(buf)

		-- Old dir is gone, new dir exists.
		assert.is_nil(helpers.fs_stat(tmpdir .. "/mydir"))
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/renamed_dir"))
		-- Children are preserved under the new name with content intact.
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/renamed_dir/nested.txt"))
		assert.equals("inside", helpers.read_file(tmpdir .. "/renamed_dir/nested.txt"))
	end)

	it("moves a file to a different parent by changing its indent", function()
		local lines = helpers.get_buffer_lines(buf)

		-- Find sourcedir/ (let's say it's lines[3]) and move_me.txt (lines[4]).
		-- We'll move move_me.txt from sourcedir/ to mydir/ by:
		-- 1. Removing it from sourcedir (deleting its line)
		-- 2. Adding it under mydir with proper indent.
		local move_line, move_idx
		local mydir_idx
		for i, line in ipairs(lines) do
			if line:match("move_me%.txt") then
				move_line = line
				move_idx = i
			end
			if line == "mydir/" then
				mydir_idx = i
			end
		end

		-- Remove the file from its current position.
		table.remove(lines, move_idx)
		-- Insert it after mydir with indent level 1 (under mydir).
		table.insert(lines, mydir_idx + 1, "  move_me.txt")
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		helpers.save_buffer(buf)

		-- File should now be under mydir, not sourcedir, with content intact.
		assert.is_nil(helpers.fs_stat(tmpdir .. "/sourcedir/move_me.txt"))
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/mydir/move_me.txt"))
		assert.equals("movable", helpers.read_file(tmpdir .. "/mydir/move_me.txt"))
	end)

	it("preserves file content when renaming in-place", function()
			-- Write a file with multiline content to ensure the full content survives.
			local f = io.open(tmpdir .. "/multiline.txt", "w")
			f:write("line one\nline two\nline three\n")
			f:close()

			-- Refresh the buffer to pick up the new file.
			helpers.close_filebuf(buf)
			buf = helpers.open_filebuf(tmpdir)

			local lines = helpers.get_buffer_lines(buf)
			for i, line in ipairs(lines) do
				if line == "multiline.txt" then
					lines[i] = "multiline_renamed.txt"
					break
				end
			end
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

			helpers.save_buffer(buf)

			-- Old file is gone, new file has the original multiline content.
			assert.is_nil(helpers.fs_stat(tmpdir .. "/multiline.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/multiline_renamed.txt"))
			assert.equals("line one\nline two\nline three\n", helpers.read_file(tmpdir .. "/multiline_renamed.txt"))
		end)

	it("handles rename + create + delete in a single save", function()
		local lines = helpers.get_buffer_lines(buf)
		-- Rename oldname.txt → newname.txt
		for i, line in ipairs(lines) do
			if line == "oldname.txt" then
				lines[i] = "renamed.txt"
				break
			end
		end
		-- Create a new file.
		lines[#lines + 1] = "brand_new.txt"
		-- Delete sourcedir/ and its contents by removing those lines.
		local filtered = {}
		local skip = false
		local current_parent_indent
		for _, line in ipairs(lines) do
			if line == "sourcedir/" then
				skip = true
				current_parent_indent = 0
			elseif skip then
				-- Keep skipping until we see a top-level entry.
				if line:match("^%S") or line:match("^%s%S") then
					-- This is the next top-level or less indented entry.
					skip = false
					filtered[#filtered + 1] = line
				end
				-- else: skip (child of sourcedir)
			else
				filtered[#filtered + 1] = line
			end
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, filtered)

		helpers.save_buffer(buf)

		-- Rename succeeded with content preserved.
		assert.is_nil(helpers.fs_stat(tmpdir .. "/oldname.txt"))
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/renamed.txt"))
		assert.equals("content", helpers.read_file(tmpdir .. "/renamed.txt"))
		-- Create succeeded.
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/brand_new.txt"))
		-- Delete succeeded.
		assert.is_nil(helpers.fs_stat(tmpdir .. "/sourcedir"))
		assert.is_nil(helpers.fs_stat(tmpdir .. "/sourcedir/move_me.txt"))
		-- Unrelated files unchanged.
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/mydir"))
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/mydir/nested.txt"))
	end)
end)
