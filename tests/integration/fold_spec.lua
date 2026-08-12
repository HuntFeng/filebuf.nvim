----------------------------------------------------------------------
-- Integration tests — fold state.
--
-- Covers the two things that have actually broken in the past:
--   1. Open/closed fold state should survive the operations that rewrite
--      the buffer (save, toggle hidden) and buffer close/reopen at the
--      same root, via filebuf.fold.open_folds.
--   2. Window-local fold options must not be reapplied on every BufEnter:
--      that repeatedly forced foldlevel=0, silently closing every fold
--      whenever focus merely bounced to another window (e.g. the K
--      preview float) and back. They are set once when filebuf takes the
--      window and restored once when the buffer is wiped (BufDelete).
----------------------------------------------------------------------
local helpers = require("tests.helpers")

describe("fold state", function()
	local tmpdir
	local buf

	before_each(function()
		tmpdir = helpers.create_temp_dir()
	end)

	after_each(function()
		helpers.close_filebuf(buf)
		helpers.cleanup_dir(tmpdir)
	end)

	--- Open the native fold for `path`'s buffer line.
	---@param path string
	local function open_fold(path)
		local entry = helpers.entry_for(buf, path)
		vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
		vim.cmd("silent! normal! zo")
	end

	--- True when `path`'s buffer line is inside a closed fold (or has none).
	---@param path string
	---@return boolean
	local function is_open(path)
		local entry = helpers.entry_for(buf, path)
		return entry ~= nil and vim.fn.foldclosed(entry.lnum) == -1
	end

	describe("survives buffer rewrites", function()
		it("stays open across a save", function()
			helpers.populate_dir(tmpdir, {
				["mydir"] = {},
				["mydir/nested.txt"] = "hi",
				["other.txt"] = "",
			})
			buf = helpers.open_filebuf(tmpdir)

			open_fold(tmpdir .. "/mydir")
			assert.is_true(is_open(tmpdir .. "/mydir"))

			local lines = helpers.get_buffer_lines(buf)
			lines[#lines + 1] = "new.txt"
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			helpers.save_buffer(buf)

			assert.is_true(is_open(tmpdir .. "/mydir"), "fold should still be open after save")
		end)

		it("stays open across toggling hidden files", function()
			helpers.populate_dir(tmpdir, {
				["mydir"] = {},
				["mydir/nested.txt"] = "hi",
				[".dotfile"] = "",
			})
			buf = helpers.open_filebuf(tmpdir)

			open_fold(tmpdir .. "/mydir")
			assert.is_true(is_open(tmpdir .. "/mydir"))

			vim.cmd("FilebufToggleHidden")
			assert.is_true(is_open(tmpdir .. "/mydir"), "fold should stay open after toggling hidden on")

			vim.cmd("FilebufToggleHidden")
			assert.is_true(is_open(tmpdir .. "/mydir"), "fold should stay open after toggling hidden off")
		end)
	end)

	describe("survives close/reopen at the same root", function()
		it("remembers an open fold when filebuf is closed and reopened", function()
			helpers.populate_dir(tmpdir, {
				["mydir"] = {},
				["mydir/nested.txt"] = "hi",
			})
			buf = helpers.open_filebuf(tmpdir)

			open_fold(tmpdir .. "/mydir")
			assert.is_true(is_open(tmpdir .. "/mydir"))

			-- Close through the plugin's own path (not helpers.close_filebuf,
			-- which resets fold.open_folds for test isolation and would mask
			-- exactly the persistence this test is checking).
			require("filebuf").close(buf)

			buf = helpers.open_filebuf(tmpdir)
			assert.is_true(is_open(tmpdir .. "/mydir"), "fold should reopen automatically on reopen")
		end)
	end)

	describe("survives focus bouncing away and back", function()
		it("keeps a fold open when another window briefly becomes current", function()
			helpers.populate_dir(tmpdir, {
				["mydir"] = {},
				["mydir/nested.txt"] = "hi",
				["other"] = {},
				["other/file.txt"] = "",
			})
			buf = helpers.open_filebuf(tmpdir)
			local filebuf_win = vim.api.nvim_get_current_win()

			open_fold(tmpdir .. "/mydir")
			assert.is_true(is_open(tmpdir .. "/mydir"))
			assert.is_false(is_open(tmpdir .. "/other"), "other/ was never opened")

			-- Simulate a focus bounce that never truly leaves the filebuf
			-- buffer (e.g. opening the K preview float and closing it): a
			-- split window becomes current, then focus returns to the
			-- filebuf window without the filebuf buffer ever being wiped.
			vim.cmd("new")
			local scratch_win = vim.api.nvim_get_current_win()
			vim.api.nvim_set_current_win(filebuf_win)
			vim.api.nvim_win_close(scratch_win, true)

			assert.equals(filebuf_win, vim.api.nvim_get_current_win())
			assert.is_true(is_open(tmpdir .. "/mydir"), "fold must survive a focus bounce, not just a save")
			assert.is_false(is_open(tmpdir .. "/other"), "unopened folds must not reopen either")
		end)
	end)

	describe("window options", function()
		it("restores the window's original fold options once filebuf is closed", function()
			local orig_foldmethod = vim.wo.foldmethod
			local orig_foldexpr = vim.wo.foldexpr

			helpers.populate_dir(tmpdir, { ["a.txt"] = "" })
			buf = helpers.open_filebuf(tmpdir)

			assert.equals("expr", vim.wo.foldmethod)
			assert.equals("v:lua.FilebufFoldExpr()", vim.wo.foldexpr)

			require("filebuf").close(buf)

			assert.equals(orig_foldmethod, vim.wo.foldmethod)
			assert.equals(orig_foldexpr, vim.wo.foldexpr)
		end)
	end)
end)
