----------------------------------------------------------------------
-- Integration tests — file and directory deletion.
-- Verifies that removing lines from the buffer deletes entries from disk after :w.
----------------------------------------------------------------------
local helpers = require("tests.helpers")

describe("delete", function()
	local tmpdir
	local buf

	before_each(function()
		tmpdir = helpers.create_temp_dir()
		helpers.populate_dir(tmpdir, {
			["remove_me.txt"] = "gone",
			["keep_me.txt"] = "stays",
			["dir_to_delete"] = {},
			["dir_to_delete/child.txt"] = "also gone",
			["empty_dir"] = {},
		})
		buf = helpers.open_filebuf(tmpdir)
	end)

	after_each(function()
		helpers.close_filebuf(buf)
		helpers.cleanup_dir(tmpdir)
	end)

	it("deletes a file when its line is removed", function()
		local lines = helpers.get_buffer_lines(buf)
		-- Remove the line containing "remove_me.txt".
		local filtered = {}
		for _, line in ipairs(lines) do
			if line ~= "remove_me.txt" then
				filtered[#filtered + 1] = line
			end
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, filtered)

		helpers.save_buffer(buf)

		-- File should be gone.
		assert.is_nil(helpers.fs_stat(tmpdir .. "/remove_me.txt"))
		-- Other files should remain.
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/keep_me.txt"))
	end)

	it("deletes an empty directory when its line is removed", function()
		local lines = helpers.get_buffer_lines(buf)
		-- Remove "empty_dir/" line.
		local filtered = {}
		for _, line in ipairs(lines) do
			if line ~= "empty_dir/" then
				filtered[#filtered + 1] = line
			end
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, filtered)

		helpers.save_buffer(buf)

		assert.is_nil(helpers.fs_stat(tmpdir .. "/empty_dir"))
	end)

	it("deletes a directory and its children when the dir line is removed", function()
		local lines = helpers.get_buffer_lines(buf)
		-- Remove "dir_to_delete/" and its children (indented under it).
		local filtered = {}
		local skipping = false
		for _, line in ipairs(lines) do
			if line == "dir_to_delete/" then
				skipping = true
			elseif skipping and (line == "" or line:match("^%S")) then
				-- A non-indented line: we're out of the subtree.
				skipping = false
				filtered[#filtered + 1] = line
			elseif not skipping then
				filtered[#filtered + 1] = line
			end
			-- else: skip (inside the deleted subtree)
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, filtered)

		helpers.save_buffer(buf)

		-- Dir and its child should both be gone.
		assert.is_nil(helpers.fs_stat(tmpdir .. "/dir_to_delete/child.txt"))
		assert.is_nil(helpers.fs_stat(tmpdir .. "/dir_to_delete"))
	end)

	it("deletes multiple entries in a single save", function()
		local lines = helpers.get_buffer_lines(buf)
		-- Remove both "remove_me.txt" and "empty_dir/".
		local filtered = {}
		for _, line in ipairs(lines) do
			if line ~= "remove_me.txt" and line ~= "empty_dir/" then
				filtered[#filtered + 1] = line
			end
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, filtered)

		helpers.save_buffer(buf)

		assert.is_nil(helpers.fs_stat(tmpdir .. "/remove_me.txt"))
		assert.is_nil(helpers.fs_stat(tmpdir .. "/empty_dir"))
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/keep_me.txt"))
	end)

	it("preserves unrelated files when deleting", function()
		local lines = helpers.get_buffer_lines(buf)
		local filtered = {}
		for _, line in ipairs(lines) do
			if line ~= "remove_me.txt" then
				filtered[#filtered + 1] = line
			end
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, filtered)

		helpers.save_buffer(buf)

		-- Everything except remove_me.txt should still exist.
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/keep_me.txt"))
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/dir_to_delete"))
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/dir_to_delete/child.txt"))
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/empty_dir"))
	end)
end)
