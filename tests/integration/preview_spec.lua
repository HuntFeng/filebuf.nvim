----------------------------------------------------------------------
-- Integration tests — file preview via K.
-- Verifies floating window creation, content display, auto-close,
-- and edge cases.
----------------------------------------------------------------------
local helpers = require("tests.helpers")

describe("preview", function()
	local tmpdir
	local buf

	before_each(function()
		tmpdir = helpers.create_temp_dir()
		helpers.populate_dir(tmpdir, {
			["hello.lua"] = "local x = 1\nreturn x\n",
			["empty.txt"] = "",
			["subdir"] = {},
			["subdir/nested.py"] = "def foo():\n    pass\n",
		})
		buf = helpers.open_filebuf(tmpdir)
		-- Expand subdir so we can see nested files.
		local actions = require("filebuf.actions")
		local entries = vim.b[buf].filebuf_display_entries
		for _, e in ipairs(entries) do
			if e.type == "dir" then
				actions.expand_dir(buf, e)
			end
		end
	end)

	after_each(function()
		local preview = require("filebuf.preview")
		preview.close()
		helpers.close_filebuf(buf)
		helpers.cleanup_dir(tmpdir)
	end)

	--- Find a floating window whose buffer has no backing file.
	--- Returns { win, buf } or nil.
	local function find_preview_win()
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			local wbuf = vim.api.nvim_win_get_buf(win)
			if vim.bo[wbuf].buftype == "nofile" and vim.bo[wbuf].bufhidden == "wipe" then
				return { win = win, buf = wbuf }
			end
		end
		return nil
	end

	--- Move cursor to the entry named `name` and return its lnum.
	local function move_to(name)
		local entries = vim.b[buf].filebuf_display_entries
		for _, e in ipairs(entries) do
			if e.name == name then
				vim.api.nvim_win_set_cursor(0, { e.lnum, 0 })
				return e.lnum
			end
		end
		return nil
	end

	it("creates a floating preview window when K is pressed on a file", function()
		move_to("hello.lua")
		local preview = require("filebuf.preview")
		local actions = require("filebuf.actions")
		local entry = actions.get_entry_at_cursor(buf)
		preview.show(buf, entry)

		local pw = find_preview_win()
		assert.is_not_nil(pw, "expected a floating preview window")
		assert.is_true(vim.api.nvim_win_is_valid(pw.win), "preview window should be valid")
		assert.is_true(vim.api.nvim_buf_is_valid(pw.buf), "preview buffer should be valid")

		-- Content should include the file contents.
		local lines = vim.api.nvim_buf_get_lines(pw.buf, 0, -1, false)
		assert.equals("local x = 1", lines[1])
		assert.equals("return x", lines[2])
	end)

	it("does nothing when K is pressed on a directory", function()
		move_to("subdir")
		local preview = require("filebuf.preview")
		local actions = require("filebuf.actions")
		local entry = actions.get_entry_at_cursor(buf)
		assert.equals("dir", entry.type)

		preview.show(buf, entry)
		local pw = find_preview_win()
		assert.is_nil(pw, "should not create a preview window for a directory")
	end)

	it("sets the correct filetype for syntax highlighting", function()
		move_to("hello.lua")
		local preview = require("filebuf.preview")
		local actions = require("filebuf.actions")
		local entry = actions.get_entry_at_cursor(buf)
		preview.show(buf, entry)

		local pw = find_preview_win()
		assert.is_not_nil(pw)
		-- The buffer should have the filetype set for highlighting (lua, python, etc.).
		local ft = vim.bo[pw.buf].filetype
		assert.is_not_nil(ft)
		assert.is_true(#ft > 0, "expected filetype to be set for syntax highlighting")
		assert.equals("lua", ft)
	end)

	it("auto-closes preview on CursorMoved", function()
		move_to("hello.lua")
		local preview = require("filebuf.preview")
		local actions = require("filebuf.actions")
		local entry = actions.get_entry_at_cursor(buf)
		preview.show(buf, entry)

		local pw = find_preview_win()
		assert.is_not_nil(pw, "preview should be open")

		-- open_floating_preview registers a CursorMoved autocmd that
		-- auto-closes the window when the cursor moves (verified by
		-- the presence of the autocmd; headless mode cannot trigger it).
		local acs = vim.api.nvim_get_autocmds({
			event = "CursorMoved",
			buffer = buf,
		})
		assert.equals(1, #acs, "expected one CursorMoved autocmd for auto-close")
	end)

	it("replaces content when K is pressed on a different file while preview is open", function()
		move_to("hello.lua")
		local preview = require("filebuf.preview")
		local actions = require("filebuf.actions")

		local entry1 = actions.get_entry_at_cursor(buf)
		preview.show(buf, entry1)
		local pw1 = find_preview_win()
		assert.is_not_nil(pw1)
		local lines1 = vim.api.nvim_buf_get_lines(pw1.buf, 0, -1, false)
		assert.equals("local x = 1", lines1[1])

		-- Preview a different file; the old window is closed and a new one opens.
		move_to("nested.py")
		local entry2 = actions.get_entry_at_cursor(buf)
		preview.show(buf, entry2)

		local pw2 = find_preview_win()
		assert.is_not_nil(pw2)
		-- Old window should be gone.
		assert.is_false(vim.api.nvim_win_is_valid(pw1.win))
		local lines2 = vim.api.nvim_buf_get_lines(pw2.buf, 0, -1, false)
		assert.equals("def foo():", lines2[1])
	end)

	it("handles empty files gracefully", function()
		move_to("empty.txt")
		local preview = require("filebuf.preview")
		local actions = require("filebuf.actions")
		local entry = actions.get_entry_at_cursor(buf)
		preview.show(buf, entry)

		local pw = find_preview_win()
		assert.is_not_nil(pw)
		local lines = vim.api.nvim_buf_get_lines(pw.buf, 0, -1, false)
		assert.equals("(empty)", lines[1])
	end)

	it("handles nonexistent files gracefully", function()
		-- Simulate an entry pointing to a path that doesn't exist.
		local preview = require("filebuf.preview")
		local fake_entry = {
			name = "gone.txt",
			type = "file",
			path = tmpdir .. "/gone.txt",
		}
		preview.show(buf, fake_entry)

		local pw = find_preview_win()
		assert.is_not_nil(pw)
		local lines = vim.api.nvim_buf_get_lines(pw.buf, 0, -1, false)
		assert.equals("(unreadable)", lines[1])
	end)
end)
