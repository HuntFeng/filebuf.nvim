----------------------------------------------------------------------
-- Integration tests — validation errors.
-- Verifies that invalid edits (type mismatches) are caught, diagnostics are
-- set, and the filesystem is NOT modified.
----------------------------------------------------------------------
local helpers = require("tests.helpers")

describe("error handling", function()
	local tmpdir
	local buf

	before_each(function()
		tmpdir = helpers.create_temp_dir()
		helpers.populate_dir(tmpdir, {
			["a_file.txt"] = "content",
			["a_dir"] = {},
			["a_dir/nested.txt"] = "inside",
		})
		buf = helpers.open_filebuf(tmpdir)
	end)

	after_each(function()
		helpers.close_filebuf(buf)
		helpers.cleanup_dir(tmpdir)
	end)

	it("rejects save when a file is changed to a directory (adding /)", function()
		local lines = helpers.get_buffer_lines(buf)
		-- Change "a_file.txt" (a file) to "a_file.txt/" (a directory).
		for i, line in ipairs(lines) do
			if line == "a_file.txt" then
				lines[i] = "a_file.txt/"
				break
			end
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		helpers.save_buffer(buf)

		-- Buffer should still be modified (save was rejected).
		assert.is_true(vim.bo[buf].modified)
		-- File should still exist on disk (unchanged).
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/a_file.txt"))
		assert.equals("file", helpers.fs_type(tmpdir .. "/a_file.txt"))
	end)

	it("rejects save when a directory is changed to a file (removing /)", function()
		local lines = helpers.get_buffer_lines(buf)
		-- Change "a_dir/" (a dir) to "a_dir" (a file).
		for i, line in ipairs(lines) do
			if line == "a_dir/" then
				lines[i] = "a_dir"
				break
			end
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		helpers.save_buffer(buf)

		-- Buffer should still be modified.
		assert.is_true(vim.bo[buf].modified)
		-- Directory should still exist on disk.
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/a_dir"))
		assert.equals("directory", helpers.fs_type(tmpdir .. "/a_dir"))
	end)

	it("sets diagnostics on the offending line", function()
		local lines = helpers.get_buffer_lines(buf)
		local err_lnum
		for i, line in ipairs(lines) do
			if line == "a_file.txt" then
				lines[i] = "a_file.txt/"
				err_lnum = i
				break
			end
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		helpers.save_buffer(buf)

		local diags = helpers.get_diagnostics(buf)
		assert.is_true(#diags > 0, "expected diagnostics to be set")
		-- The diagnostic should be at the offending line.
		-- (diagnostics are 0-indexed, buffer lines are 1-indexed)
		local found = false
		for _, d in ipairs(diags) do
			if d.lnum == err_lnum - 1 then
				found = true
				break
			end
		end
		assert.is_true(found, "expected diagnostic at line " .. err_lnum)
	end)

	it("does not modify any filesystem state on error", function()
		-- Capture original state.
		local original_file_stat = helpers.fs_stat(tmpdir .. "/a_file.txt")
		local original_dir_stat = helpers.fs_stat(tmpdir .. "/a_dir")

		local lines = helpers.get_buffer_lines(buf)
		for i, line in ipairs(lines) do
			if line == "a_file.txt" then
				lines[i] = "a_file.txt/"
				break
			end
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		helpers.save_buffer(buf)

		-- All files should still exist with their original types.
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/a_file.txt"))
		assert.equals("file", helpers.fs_type(tmpdir .. "/a_file.txt"))
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/a_dir"))
		assert.equals("directory", helpers.fs_type(tmpdir .. "/a_dir"))
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/a_dir/nested.txt"))
	end)

	it("error message mentions the type mismatch", function()
		local lines = helpers.get_buffer_lines(buf)
		for i, line in ipairs(lines) do
			if line == "a_file.txt" then
				lines[i] = "a_file.txt/"
				break
			end
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		helpers.save_buffer(buf)

		local diags = helpers.get_diagnostics(buf)
		assert.is_true(#diags > 0)
		-- The message should mention "file" and "dir" (the type mismatch).
		local msg = diags[1].message:lower()
		assert.is_true(msg:find("file") ~= nil or msg:find("dir") ~= nil,
			"expected error message to mention file/dir types, got: " .. diags[1].message)
	end)

	it("allows valid edits when previous save was rejected", function()
		local lines = helpers.get_buffer_lines(buf)

		-- First, make an invalid edit (type mismatch).
		for i, line in ipairs(lines) do
			if line == "a_file.txt" then
				lines[i] = "a_file.txt/"
				break
			end
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		helpers.save_buffer(buf)
		assert.is_true(vim.bo[buf].modified) -- save was rejected

		-- Now fix the edit and try again.
		lines = helpers.get_buffer_lines(buf)
		for i, line in ipairs(lines) do
			if line == "a_file.txt/" then
				lines[i] = "a_file.txt"
				break
			end
		end
		lines[#lines + 1] = "new_valid_file.txt"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		helpers.save_buffer(buf)

		-- This time save should succeed.
		assert.is_false(vim.bo[buf].modified)
		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/new_valid_file.txt"))
		-- Diagnostics should be cleared.
		local diags = helpers.get_diagnostics(buf)
		assert.equals(0, #diags)
	end)
end)
