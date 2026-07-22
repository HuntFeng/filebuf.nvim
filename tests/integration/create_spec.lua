----------------------------------------------------------------------
-- Integration tests — file and directory creation.
-- Verifies that editing the buffer to add entries creates them on disk after :w.
----------------------------------------------------------------------
local helpers = require("tests.helpers")

describe("create", function()
	local tmpdir
	local buf

	before_each(function()
		tmpdir = helpers.create_temp_dir()
		helpers.populate_dir(tmpdir, {
			["existing.txt"] = "hello",
			["subdir"] = {},
		})
		buf = helpers.open_filebuf(tmpdir)
	end)

	after_each(function()
		helpers.close_filebuf(buf)
		helpers.cleanup_dir(tmpdir)
	end)

	it("creates a new file at root level", function()
		-- Append a new line for the file to create.
		local lines = helpers.get_buffer_lines(buf)
		lines[#lines + 1] = "newfile.txt"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		helpers.save_buffer(buf)

		local stat = helpers.fs_stat(tmpdir .. "/newfile.txt")
		assert.is_not_nil(stat)
		assert.equals("file", stat.type)
	end)

	it("creates a new directory at root level", function()
		local lines = helpers.get_buffer_lines(buf)
		lines[#lines + 1] = "newdir/"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		helpers.save_buffer(buf)

		local stat = helpers.fs_stat(tmpdir .. "/newdir")
		assert.is_not_nil(stat)
		assert.equals("directory", stat.type)
	end)

	it("creates a nested file inside an existing directory", function()
		local lines = helpers.get_buffer_lines(buf)
		-- Find subdir/ and insert the nested file right after it (indented).
		local subdir_idx
		for i, line in ipairs(lines) do
			if line == "subdir/" then
				subdir_idx = i
				break
			end
		end
		assert.is_not_nil(subdir_idx, "subdir/ not found in buffer")
		table.insert(lines, subdir_idx + 1, "  nested.txt")
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		helpers.save_buffer(buf)

		local stat = helpers.fs_stat(tmpdir .. "/subdir/nested.txt")
		assert.is_not_nil(stat)
		assert.equals("file", stat.type)
	end)

	it("creates multiple files and dirs in a single save", function()
		local lines = helpers.get_buffer_lines(buf)
		lines[#lines + 1] = "alpha.txt"
		lines[#lines + 1] = "newsub/"
		lines[#lines + 1] = "  beta.txt"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		helpers.save_buffer(buf)

		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/alpha.txt"))
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/newsub"))
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/newsub/beta.txt"))
	end)

	it("creates intermediate directories when name contains /", function()
		local lines = helpers.get_buffer_lines(buf)
		lines[#lines + 1] = "deep/nested/file.txt"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		helpers.save_buffer(buf)

		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/deep"))
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/deep/nested"))
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/deep/nested/file.txt"))
	end)

	it("does not delete existing files when creating new ones", function()
		local lines = helpers.get_buffer_lines(buf)
		lines[#lines + 1] = "newfile.txt"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		helpers.save_buffer(buf)

		-- Existing files should still be present.
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/existing.txt"))
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/subdir"))
		-- And the new file should exist.
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/newfile.txt"))
	end)

	it("marks the buffer as not modified after a successful save", function()
		local lines = helpers.get_buffer_lines(buf)
		lines[#lines + 1] = "newfile.txt"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		assert.is_true(vim.bo[buf].modified)

		helpers.save_buffer(buf)

		assert.is_false(vim.bo[buf].modified)
	end)
end)
