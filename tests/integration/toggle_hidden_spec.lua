----------------------------------------------------------------------
-- Integration tests — toggling show_hidden mid-edit.
-- Verifies that toggling hidden-file visibility while the buffer has
-- unsaved edits preserves those edits and does not affect the saved
-- results (hidden files shouldn't be treated as newly created or
-- deleted entries).
----------------------------------------------------------------------
local helpers = require("tests.helpers")

describe("toggle hidden mid-edit", function()
	local tmpdir
	local buf

	before_each(function()
		tmpdir = helpers.create_temp_dir()
		require("filebuf.config").show_hidden = false
	end)

	after_each(function()
		helpers.close_filebuf(buf)
		helpers.cleanup_dir(tmpdir)
		require("filebuf.config").show_hidden = false
	end)

	--- Invoke :FilebufToggleHidden — the user-facing command that mirrors
	--- pressing "gh" in a real filebuf buffer.
	local function toggle_hidden()
		vim.cmd("FilebufToggleHidden")
	end

	describe("create mid-edit with toggle", function()

		it("saving while hidden is on mid-edit does not treat hidden files as new", function()
			helpers.populate_dir(tmpdir, {
				["a.txt"] = "",
				[".one"] = "1",
				[".two"] = "2",
			})
			buf = helpers.open_filebuf(tmpdir)

			-- Add a new file, then toggle hidden ON.
			local lines = helpers.get_buffer_lines(buf)
			lines[#lines + 1] = "really_new.txt"
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			toggle_hidden()

			-- Save while hidden files are visible.
			helpers.save_buffer(buf)

			-- Only the actually-new file should have been created.
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/really_new.txt"))
			-- Hidden files must still exist — they were never deleted.
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/.one"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/.two"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/a.txt"))
			assert.is_false(vim.bo[buf].modified)
		end)

		it("preserves a nested file create after toggling hidden", function()
			helpers.populate_dir(tmpdir, {
				["mydir"] = {},
				["mydir/existing.txt"] = "",
				[".hidden_dir"] = {},
			})
			buf = helpers.open_filebuf(tmpdir)

			-- Add a nested file under mydir/.
			local lines = helpers.get_buffer_lines(buf)
			for i, l in ipairs(lines) do
				if l == "mydir/" then
					table.insert(lines, i + 1, "  new_nested.txt")
					break
				end
			end
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

			-- Toggle on and off.
			toggle_hidden()
			toggle_hidden()

			lines = helpers.get_buffer_lines(buf)
			local found = false
			for _, l in ipairs(lines) do
				if l:match("new_nested%.txt") then
					found = true
				end
			end
			assert.is_true(found, "nested new file should survive toggles")

			helpers.save_buffer(buf)

			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/mydir/new_nested.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/.hidden_dir"))
		end)
	end)

	describe("delete mid-edit with toggle", function()

		it("preserves a delete when saving with hidden toggled on", function()
			helpers.populate_dir(tmpdir, {
				["vanish.txt"] = "poof",
				[".stays.txt"] = "dot",
			})
			buf = helpers.open_filebuf(tmpdir)

			-- Delete visible file, then toggle hidden ON.
			local lines = helpers.get_buffer_lines(buf)
			local filtered = {}
			for _, l in ipairs(lines) do
				if l ~= "vanish.txt" then
					filtered[#filtered + 1] = l
				end
			end
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, filtered)
			toggle_hidden()

			-- Save while hidden is visible.
			helpers.save_buffer(buf)

			assert.is_nil(helpers.fs_stat(tmpdir .. "/vanish.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/.stays.txt"))
			assert.is_false(vim.bo[buf].modified)
		end)
	end)

	describe("rename mid-edit with toggle", function()
		it("preserves a rename after toggling hidden on and off", function()
			helpers.populate_dir(tmpdir, {
				["old_name.txt"] = "content",
				[".hidden"] = "shh",
			})
			buf = helpers.open_filebuf(tmpdir)

			-- Rename in-place.
			local lines = helpers.get_buffer_lines(buf)
			for i, l in ipairs(lines) do
				if l == "old_name.txt" then
					lines[i] = "new_name.txt"
					break
				end
			end
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

			-- Toggle hidden on and off.
			toggle_hidden()
			toggle_hidden()

			lines = helpers.get_buffer_lines(buf)
			local found_old = false
			local found_new = false
			for _, l in ipairs(lines) do
				if l == "old_name.txt" then
					found_old = true
				end
				if l == "new_name.txt" then
					found_new = true
				end
			end
			assert.is_false(found_old, "old name should be gone")
			assert.is_true(found_new, "new name should be present")

			helpers.save_buffer(buf)

			assert.is_nil(helpers.fs_stat(tmpdir .. "/old_name.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/new_name.txt"))
			assert.equals("content", helpers.read_file(tmpdir .. "/new_name.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/.hidden"))
		end)

		it("preserves a rename when saving with hidden toggled on", function()
			helpers.populate_dir(tmpdir, {
				["before.txt"] = "data",
				[".dotfile"] = "dot",
			})
			buf = helpers.open_filebuf(tmpdir)

			local lines = helpers.get_buffer_lines(buf)
			for i, l in ipairs(lines) do
				if l == "before.txt" then
					lines[i] = "after.txt"
					break
				end
			end
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			toggle_hidden()

			helpers.save_buffer(buf)

			assert.is_nil(helpers.fs_stat(tmpdir .. "/before.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/after.txt"))
			assert.equals("data", helpers.read_file(tmpdir .. "/after.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/.dotfile"))
		end)
	end)

	describe("mixed operations mid-edit with toggle", function()
	end)

	describe("toggle when show_hidden starts ON", function()
		before_each(function()
			require("filebuf.config").show_hidden = true
		end)


		it("preserves a delete after toggling hidden off and back on", function()
			helpers.populate_dir(tmpdir, {
				["trash_me.txt"] = "bye",
				[".dotfile"] = "dot",
			})
			buf = helpers.open_filebuf(tmpdir)

			-- Delete a visible file.
			local lines = helpers.get_buffer_lines(buf)
			local filtered = {}
			for _, l in ipairs(lines) do
				if l ~= "trash_me.txt" then
					filtered[#filtered + 1] = l
				end
			end
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, filtered)

			-- Toggle off.
			toggle_hidden()
			lines = helpers.get_buffer_lines(buf)
			local found_trash = false
			for _, l in ipairs(lines) do
				if l:match("trash_me") then
					found_trash = true
				end
			end
			assert.is_false(found_trash, "deleted file should not reappear")

			-- Toggle on.
			toggle_hidden()
			lines = helpers.get_buffer_lines(buf)
			found_trash = false
			local found_dot = false
			for _, l in ipairs(lines) do
				if l:match("trash_me") then
					found_trash = true
				end
				if l:match("%.dotfile") then
					found_dot = true
				end
			end
			assert.is_false(found_trash, "deleted file should still be gone")
			assert.is_true(found_dot, "dotfile should be visible again")

			helpers.save_buffer(buf)

			assert.is_nil(helpers.fs_stat(tmpdir .. "/trash_me.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/.dotfile"))
		end)
	end)

	describe("modified flag semantics", function()
		it("remains modified after toggling hidden with unsaved edits", function()
			helpers.populate_dir(tmpdir, {
				["real.txt"] = "real",
				[".secret.txt"] = "secret",
			})
			buf = helpers.open_filebuf(tmpdir)

			-- Make an edit.
			local lines = helpers.get_buffer_lines(buf)
			lines[#lines + 1] = "new.txt"
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			assert.is_true(vim.bo[buf].modified)

			-- Toggle on: modified must stay true.
			toggle_hidden()
			assert.is_true(vim.bo[buf].modified, "modified should remain true after toggle on with edits")

			-- Toggle off: modified must stay true.
			toggle_hidden()
			assert.is_true(vim.bo[buf].modified, "modified should remain true after toggle off with edits")

			-- Save clears it.
			helpers.save_buffer(buf)
			assert.is_false(vim.bo[buf].modified)
		end)

		it("does not mark buffer as modified when toggling with no edits", function()
			helpers.populate_dir(tmpdir, {
				["real.txt"] = "",
				[".secret"] = "",
			})
			buf = helpers.open_filebuf(tmpdir)
			assert.is_false(vim.bo[buf].modified)

			toggle_hidden()
			assert.is_false(vim.bo[buf].modified, "toggle with no edits should not mark modified")

			toggle_hidden()
			assert.is_false(vim.bo[buf].modified, "toggle back with no edits should not mark modified")
		end)
	end)

	describe("sequence: toggle → edit → toggle", function()
		it("toggling hidden BEFORE editing works correctly", function()
			helpers.populate_dir(tmpdir, {
				["keep.txt"] = "",
				[".hide.txt"] = "",
			})
			buf = helpers.open_filebuf(tmpdir)

			-- Toggle hidden on first (no edits).
			toggle_hidden()

			-- Now make an edit.
			local lines = helpers.get_buffer_lines(buf)
			lines[#lines + 1] = "late_add.txt"
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

			-- Toggle off and on.
			toggle_hidden()
			toggle_hidden()

			local late_add_found = false
			for _, l in ipairs(helpers.get_buffer_lines(buf)) do
				if l:match("late_add") then
					late_add_found = true
				end
			end
			assert.is_true(late_add_found, "late_add should survive toggles")

			helpers.save_buffer(buf)

			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/late_add.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/.hide.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/keep.txt"))
		end)
	end)

	describe("disk baseline lifecycle", function()
		it("clears the disk baseline after save so the next edit+toggle cycle works", function()
			helpers.populate_dir(tmpdir, {
				["first.txt"] = "first",
				[".dots.txt"] = "dots",
			})
			buf = helpers.open_filebuf(tmpdir)

			-- Cycle 1: edit + toggle + save.
			local lines = helpers.get_buffer_lines(buf)
			lines[#lines + 1] = "cycle1.txt"
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			toggle_hidden()
			helpers.save_buffer(buf)
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/cycle1.txt"))
			assert.is_false(vim.bo[buf].modified)

			-- Cycle 2: another edit + toggle + save.
			lines = helpers.get_buffer_lines(buf)
			lines[#lines + 1] = "cycle2.txt"
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			toggle_hidden()
			helpers.save_buffer(buf)

			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/cycle2.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/cycle1.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/.dots.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/first.txt"))
			assert.is_false(vim.bo[buf].modified)
		end)

		it("handles multiple saves across toggle states", function()
			helpers.populate_dir(tmpdir, {
				["a.txt"] = "",
				[".h.txt"] = "",
			})
			buf = helpers.open_filebuf(tmpdir)

			-- First edit: save with hidden off.
			local lines = helpers.get_buffer_lines(buf)
			lines[#lines + 1] = "one.txt"
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			helpers.save_buffer(buf)
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/one.txt"))

			-- Second edit: toggle on, save with hidden on.
			lines = helpers.get_buffer_lines(buf)
			lines[#lines + 1] = "two.txt"
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			toggle_hidden()
			helpers.save_buffer(buf)
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/two.txt"))

			-- Third edit: toggle off, save with hidden off.
			lines = helpers.get_buffer_lines(buf)
			lines[#lines + 1] = "three.txt"
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			toggle_hidden()
			helpers.save_buffer(buf)
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/three.txt"))

			-- All files should still exist.
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/a.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/.h.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/one.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/two.txt"))
			assert.is_not_nil(helpers.fs_stat(tmpdir .. "/three.txt"))
			assert.is_false(vim.bo[buf].modified)
		end)
	end)
end)
