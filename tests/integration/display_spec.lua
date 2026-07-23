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

describe("hidden files", function()
	local tmpdir
	local buf

	before_each(function()
		tmpdir = helpers.create_temp_dir()
		-- Disable ignore-file support so fd/find sees all entries.
		-- Hidden files (dotfiles) are still tagged is_hidden and filtered
		-- by filter_visible when show_hidden=false.
		require("filebuf.config").respect_ignore = false
	end)

	after_each(function()
		helpers.close_filebuf(buf)
		helpers.cleanup_dir(tmpdir)
	end)

	it("hides dotfiles when show_hidden is false", function()
		helpers.populate_dir(tmpdir, {
			["visible.txt"] = "",
			[".hidden_file"] = "",
			[".hiddendir"] = {},
		})
		buf = helpers.open_filebuf(tmpdir)
		local lines = helpers.get_buffer_lines(buf)

		-- visible.txt should appear; dotfiles should not.
		local names = {}
		for _, l in ipairs(lines) do
			names[l] = true
		end
		assert.is_true(names["visible.txt"], "visible.txt should be present")
		assert.is_nil(names[".hidden_file"], ".hidden_file should be hidden")
		assert.is_nil(names[".hiddendir/"], ".hiddendir/ should be hidden")
	end)

	it("shows dotfiles after setting show_hidden = true", function()
		helpers.populate_dir(tmpdir, {
			["visible.txt"] = "",
			[".secret.txt"] = "",
		})
		-- Open with show_hidden false first.
		buf = helpers.open_filebuf(tmpdir)

		-- Re-open with show_hidden=true to simulate toggling gh.
		require("filebuf.config").show_hidden = true
		helpers.close_filebuf(buf)
		buf = helpers.open_filebuf(tmpdir)

		local lines = helpers.get_buffer_lines(buf)
		local names = {}
		for _, l in ipairs(lines) do
			names[l] = true
		end
		assert.is_true(names["visible.txt"], "visible.txt should be present")
		assert.is_true(names[".secret.txt"], ".secret.txt should be visible after toggle")

		-- Restore.
		require("filebuf.config").show_hidden = false
	end)

	it("hides dotfiles again after setting show_hidden back to false", function()
		helpers.populate_dir(tmpdir, {
			["visible.txt"] = "",
			[".secret.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)

		-- Show all.
		require("filebuf.config").show_hidden = true
		helpers.close_filebuf(buf)
		buf = helpers.open_filebuf(tmpdir)
		local lines = helpers.get_buffer_lines(buf)
		local names = {}
		for _, l in ipairs(lines) do
			names[l] = true
		end
		assert.is_true(names[".secret.txt"], ".secret.txt should be visible")

		-- Hide again.
		require("filebuf.config").show_hidden = false
		helpers.close_filebuf(buf)
		buf = helpers.open_filebuf(tmpdir)
		lines = helpers.get_buffer_lines(buf)
		names = {}
		for _, l in ipairs(lines) do
			names[l] = true
		end
		assert.is_nil(names[".secret.txt"], ".secret.txt should be hidden again")
		assert.is_true(names["visible.txt"], "visible.txt should still be visible")
	end)

	it("shows hidden directories with trailing / when show_hidden is true", function()
		helpers.populate_dir(tmpdir, {
			["normal.txt"] = "",
			[".hidden_dir"] = {},
			[".hidden_dir/nested.txt"] = "",
		})
		-- Open with show_hidden=true.
		require("filebuf.config").show_hidden = true
		buf = helpers.open_filebuf(tmpdir)

		local lines = helpers.get_buffer_lines(buf)
		-- .hidden_dir/ should appear with trailing "/".
		local found = false
		for _, l in ipairs(lines) do
			if l == ".hidden_dir/" then
				found = true
				break
			end
		end
		assert.is_true(found, "expected .hidden_dir/ to be visible")

		-- Restore.
		require("filebuf.config").show_hidden = false
	end)
end)

describe("git status", function()
	local tmpdir
	local buf

	before_each(function()
		tmpdir = helpers.create_temp_dir()
		local ok = helpers.git_init(tmpdir)
		if not ok then
			error("failed to init git repo in " .. tmpdir)
		end
	end)

	after_each(function()
		helpers.close_filebuf(buf)
		helpers.cleanup_dir(tmpdir)
	end)

	it("returns nil git status outside a git repo", function()
		-- Use a non-git temp dir.
		local non_git = helpers.create_temp_dir()
		helpers.populate_dir(non_git, { ["f.txt"] = "" })
		local git = require("filebuf.git")
		local map = git.get_status_map(non_git)
		-- get_status_map returns nil when not in a git repo.
		assert.is_nil(map)
		helpers.cleanup_dir(non_git)
	end)

	it("detects untracked files", function()
		helpers.populate_dir(tmpdir, {
			["new_file.txt"] = "hello",
			["sub"] = {},
		})
		buf = helpers.open_filebuf(tmpdir)
		local status = helpers.wait_for_git_status(buf)
		assert.is_not_nil(status, "expected git status map to exist")

		-- Untracked → "?? filename" in porcelain → "U" display char.
		local git = require("filebuf.git")
		local char, _ = git.entry_status(
			{ path = tmpdir .. "/new_file.txt", type = "file" },
			status
		)
		assert.equals("U", char)
	end)

	it("detects staged (added) files", function()
		helpers.populate_dir(tmpdir, { ["staged.txt"] = "content" })
		helpers.git_add(tmpdir, "staged.txt")

		buf = helpers.open_filebuf(tmpdir)
		local status = helpers.wait_for_git_status(buf)
		assert.is_not_nil(status)

		local git = require("filebuf.git")
		local char, _ = git.entry_status(
			{ path = tmpdir .. "/staged.txt", type = "file" },
			status
		)
		-- Staged new file → "A " in porcelain → "A" display char.
		assert.equals("A", char)
	end)

	it("detects modified files", function()
		-- Create + commit a file, then modify it to get "modified" status.
		helpers.populate_dir(tmpdir, { ["mod.txt"] = "original" })
		helpers.git_add(tmpdir, "mod.txt")
		helpers.git_commit(tmpdir, "initial commit")
		-- Modify the file.
		local fd = vim.loop.fs_open(tmpdir .. "/mod.txt", "w", 420)
		vim.loop.fs_write(fd, "modified content")
		vim.loop.fs_close(fd)

		buf = helpers.open_filebuf(tmpdir)
		local status = helpers.wait_for_git_status(buf)
		assert.is_not_nil(status)

		local git = require("filebuf.git")
		local char, _ = git.entry_status(
			{ path = tmpdir .. "/mod.txt", type = "file" },
			status
		)
		-- Modified in worktree → " M" in porcelain → "M" display char.
		assert.equals("M", char)
	end)

	it("aggregates status for parent directories", function()
		helpers.populate_dir(tmpdir, {
			["sub"] = {},
			["sub/staged.txt"] = "staged",
		})
		helpers.git_add(tmpdir, "sub/staged.txt")

		buf = helpers.open_filebuf(tmpdir)
		local status = helpers.wait_for_git_status(buf)
		assert.is_not_nil(status)

		local git = require("filebuf.git")
		local segments = git.dir_status(
			{ path = tmpdir .. "/sub", type = "dir" },
			status
		)
		-- The "sub" directory should have aggregated status from staged.txt.
		assert.is_not_nil(segments, "expected aggregated git status for directory")
		assert.is_true(#segments > 0, "expected at least one status segment")
		assert.equals("A", segments[1].char)
	end)

	it("shows no git status for clean files", function()
		helpers.populate_dir(tmpdir, { ["clean.txt"] = "clean" })
		helpers.git_add(tmpdir, "clean.txt")
		helpers.git_commit(tmpdir, "commit")

		buf = helpers.open_filebuf(tmpdir)
		local status = helpers.wait_for_git_status(buf)
		assert.is_not_nil(status)

		local git = require("filebuf.git")
		local char, _ = git.entry_status(
			{ path = tmpdir .. "/clean.txt", type = "file" },
			status
		)
		-- Committed, unmodified files have no status indicator.
		assert.is_nil(char)
	end)
end)
