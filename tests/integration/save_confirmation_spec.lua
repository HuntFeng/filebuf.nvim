----------------------------------------------------------------------
-- Integration tests — save confirmation.
-- Verifies that save_confirmation config controls the confirmation
-- dialog shown before :w applies changes to the filesystem.
----------------------------------------------------------------------
local helpers = require("tests.helpers")

describe("save confirmation", function()
	local tmpdir
	local buf

	before_each(function()
		tmpdir = helpers.create_temp_dir()
		-- Default: confirmation enabled.
		require("filebuf.config").save_confirmation = true
		require("filebuf.config").permanent_delete = true
	end)

	after_each(function()
		helpers.close_filebuf(buf)
		helpers.cleanup_dir(tmpdir)
		-- Restore defaults.
		require("filebuf.config").save_confirmation = true
		require("filebuf.config").permanent_delete = false
	end)

	describe("with save_confirmation enabled", function()
		it("applies changes after confirmation (headless returns default Yes)", function()
			helpers.populate_dir(tmpdir, {
				["existing.txt"] = "hello",
			})
			buf = helpers.open_filebuf(tmpdir)

			-- Create a new file by appending a line.
			local lines = helpers.get_buffer_lines(buf)
			lines[#lines + 1] = "newfile.txt"
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			assert.is_true(vim.bo[buf].modified, "buffer should be modified")

			-- Save — in headless mode vim.fn.confirm returns 1 (Yes).
			helpers.save_buffer(buf)

			-- File should have been created.
			local stat = helpers.fs_stat(tmpdir .. "/newfile.txt")
			assert.is_not_nil(stat)
			assert.equals("file", stat.type)
		end)

		it("cancels save when user picks No in confirmation", function()
			helpers.populate_dir(tmpdir, {
				["keep.txt"] = "stay",
			})
			buf = helpers.open_filebuf(tmpdir)

			-- Edit: create a new file.
			local lines = helpers.get_buffer_lines(buf)
			lines[#lines + 1] = "should_not_exist.txt"
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			assert.is_true(vim.bo[buf].modified, "buffer should be modified")

			-- Mock vim.fn.confirm to return 2 (No / cancel).
			local orig_confirm = vim.fn.confirm
			vim.fn.confirm = function(_, _2, _3, _4)
				return 2
			end

			helpers.save_buffer(buf)

			-- Restore the real confirm.
			vim.fn.confirm = orig_confirm

			-- File should NOT have been created — save was cancelled.
			assert.is_nil(helpers.fs_stat(tmpdir .. "/should_not_exist.txt"))
			-- keep.txt should still exist.
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/keep.txt"))
			-- Buffer should still be modified (changes were not applied).
			assert.is_true(vim.bo[buf].modified, "buffer should still be modified after cancelled save")
		end)

		it("deletes a file after confirmation", function()
			helpers.populate_dir(tmpdir, {
				["remove_me.txt"] = "bye",
				["keep_me.txt"] = "stay",
			})
			buf = helpers.open_filebuf(tmpdir)

			-- Delete by removing the line for remove_me.txt.
			local lines = helpers.get_buffer_lines(buf)
			local new_lines = {}
			for _, l in ipairs(lines) do
				if not l:match("remove_me") then
					new_lines[#new_lines + 1] = l
				end
			end
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)

			helpers.save_buffer(buf)

			-- remove_me.txt should be gone.
			assert.is_nil(helpers.fs_stat(tmpdir .. "/remove_me.txt"))
			-- keep_me.txt should still exist.
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/keep_me.txt"))
		end)

		it("renames a file after confirmation", function()
			helpers.populate_dir(tmpdir, {
				["old_name.txt"] = "content",
			})
			buf = helpers.open_filebuf(tmpdir)

			-- Rename by editing the line.
			local lines = helpers.get_buffer_lines(buf)
			for i, l in ipairs(lines) do
				if l:match("old_name") then
					lines[i] = l:gsub("old_name", "new_name")
				end
			end
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

			helpers.save_buffer(buf)

			-- Old should be gone, new should exist.
			assert.is_nil(helpers.fs_stat(tmpdir .. "/old_name.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/new_name.txt"))
		end)
	end)

	describe("with save_confirmation disabled", function()
		it("saves without confirmation when disabled", function()
			require("filebuf.config").save_confirmation = false

			helpers.populate_dir(tmpdir, {
				["existing.txt"] = "hello",
			})
			buf = helpers.open_filebuf(tmpdir)

			local lines = helpers.get_buffer_lines(buf)
			lines[#lines + 1] = "newfile.txt"
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

			helpers.save_buffer(buf)

			local stat = helpers.fs_stat(tmpdir .. "/newfile.txt")
			assert.is_not_nil(stat)
			assert.equals("file", stat.type)
		end)
	end)

	describe("no changes", function()
		it("does not prompt when there are no changes", function()
			helpers.populate_dir(tmpdir, {
				["file.txt"] = "hello",
			})
			buf = helpers.open_filebuf(tmpdir)

			-- Save immediately without making any edits.
			helpers.save_buffer(buf)

			-- File should still exist unchanged.
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/file.txt"))
		end)
	end)
end)
