----------------------------------------------------------------------
-- Integration tests — lazy loading and reveal.
--
-- Opening a filebuf loads only the root's immediate children.  Children
-- appear when a directory is expanded (actions.expand_dir) or when a path is
-- revealed (actions.reveal_path), which loads just the ancestor chain and
-- leaves sibling subdirectories unexpanded.
----------------------------------------------------------------------
local helpers = require("tests.helpers")
local actions = require("filebuf.actions")
local config = require("filebuf.config")

--- Locate a display entry by absolute path.  Re-reads vim.b every call, since
--- each expansion replaces the list and shifts lnums.
local function entry_at(buf, path)
	for _, e in ipairs(vim.b[buf].filebuf_display_entries or {}) do
		if e.path == path then
			return e
		end
	end
	return nil
end

describe("lazy loading", function()
	local tmpdir
	local buf

	before_each(function()
		tmpdir = helpers.create_temp_dir()
		config.show_hidden = false
		config.respect_ignore = false
		-- Off by default here so expand tests aren't gated on a dialog; the
		-- confirmation itself has dedicated tests below.
		config.expand_confirm_threshold = false
	end)

	after_each(function()
		helpers.close_filebuf(buf)
		helpers.cleanup_dir(tmpdir)
		config.show_hidden = false
		config.respect_ignore = false
		config.max_expand_entries = 20000
		config.expand_confirm_threshold = 1000
	end)

	------------------------------------------------------------------
	-- Initial load
	------------------------------------------------------------------

	it("renders only top-level entries on open", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/b"] = {},
			["a/b/c"] = {},
			["a/b/c/deep.txt"] = "",
			["top.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		assert.same({ "a/", "top.txt" }, helpers.get_buffer_lines(buf))
	end)

	it("does not stat or list a huge unexpanded subtree", function()
		-- Purely structural: the buffer is one line regardless of what's inside.
		local structure = { ["big"] = {} }
		for i = 1, 50 do
			structure["big/file_" .. i .. ".txt"] = ""
		end
		helpers.populate_dir(tmpdir, structure)
		buf = helpers.open_filebuf(tmpdir)
		assert.same({ "big/" }, helpers.get_buffer_lines(buf))
	end)

	------------------------------------------------------------------
	-- expand_dir
	------------------------------------------------------------------

	it("expand_dir inserts exactly the immediate children", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/child.txt"] = "",
			["a/sub"] = {},
			["a/sub/grandchild.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		assert.is_true(helpers.expand(buf, tmpdir .. "/a"))

		local lines = helpers.get_buffer_lines(buf)
		assert.same({ "a/", "  sub/", "  child.txt" }, lines)
		-- Grandchildren stay unloaded.
		assert.is_nil(entry_at(buf, tmpdir .. "/a/sub/grandchild.txt"))
		assert.is_true(entry_at(buf, tmpdir .. "/a/sub").lazy)
	end)

	it("expanding down three levels produces increasing indent", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/b"] = {},
			["a/b/c"] = {},
			["a/b/c/deep.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		helpers.expand(buf, tmpdir .. "/a")
		helpers.expand(buf, tmpdir .. "/a/b")
		helpers.expand(buf, tmpdir .. "/a/b/c")
		assert.same({ "a/", "  b/", "    c/", "      deep.txt" }, helpers.get_buffer_lines(buf))
	end)

	it("expand_dir clears the lazy flag and is idempotent", function()
		helpers.populate_dir(tmpdir, { ["a"] = {}, ["a/child.txt"] = "" })
		buf = helpers.open_filebuf(tmpdir)

		local e = entry_at(buf, tmpdir .. "/a")
		assert.is_true(e.lazy)
		actions.expand_dir(buf, e)
		assert.is_nil(entry_at(buf, tmpdir .. "/a").lazy)
		local after_first = helpers.get_buffer_lines(buf)

		-- Second call on the (now stale) entry object must not duplicate lines.
		actions.expand_dir(buf, e)
		assert.same(after_first, helpers.get_buffer_lines(buf))
	end)

	it("expand_dir returns the number of children loaded", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/one.txt"] = "",
			["a/two.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		local e = entry_at(buf, tmpdir .. "/a")
		assert.equals(2, actions.expand_dir(buf, e))
		-- Already expanded → 0.
		assert.equals(0, actions.expand_dir(buf, e))
	end)

	it("leaves the buffer unmodified after expanding (not a user edit)", function()
		helpers.populate_dir(tmpdir, { ["a"] = {}, ["a/child.txt"] = "" })
		buf = helpers.open_filebuf(tmpdir)
		helpers.expand(buf, tmpdir .. "/a")
		assert.is_false(vim.bo[buf].modified)
	end)

	it("records expanded dirs in filebuf_lazy_expanded", function()
		helpers.populate_dir(tmpdir, { ["a"] = {}, ["a/child.txt"] = "" })
		buf = helpers.open_filebuf(tmpdir)
		helpers.expand(buf, tmpdir .. "/a")
		assert.is_true(vim.b[buf].filebuf_lazy_expanded[tmpdir .. "/a"])
	end)

	------------------------------------------------------------------
	-- reveal_path
	------------------------------------------------------------------

	it("reveal_path loads the ancestor chain and returns the target", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/b"] = {},
			["a/b/c"] = {},
			["a/b/c/file.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		local target = actions.reveal_path(buf, tmpdir .. "/a/b/c/file.txt")
		assert.is_not_nil(target)
		assert.equals("file.txt", target.name)
		assert.equals(tmpdir .. "/a/b/c/file.txt", target.path)
		assert.equals(3, target.indent)
		assert.same({ "a/", "  b/", "    c/", "      file.txt" }, helpers.get_buffer_lines(buf))
		-- The returned lnum is usable straight away.
		assert.equals("      file.txt", helpers.get_buffer_lines(buf)[target.lnum])
	end)

	it("reveal_path does not expand sibling subdirectories", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/sibling"] = {},
			["a/sibling/untouched.txt"] = "",
			["a/b"] = {},
			["a/b/file.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		assert.is_not_nil(actions.reveal_path(buf, tmpdir .. "/a/b/file.txt"))

		-- The sibling is listed (it is a child of the expanded "a") ...
		assert.is_not_nil(entry_at(buf, tmpdir .. "/a/sibling"))
		assert.is_true(entry_at(buf, tmpdir .. "/a/sibling").lazy, "sibling must stay lazy")
		-- ... but its contents were never loaded.
		assert.is_nil(entry_at(buf, tmpdir .. "/a/sibling/untouched.txt"))
	end)

	it("reveal_path can reveal a directory itself", function()
		helpers.populate_dir(tmpdir, { ["a"] = {}, ["a/b"] = {}, ["a/b/c"] = {} })
		buf = helpers.open_filebuf(tmpdir)
		local target = actions.reveal_path(buf, tmpdir .. "/a/b/c")
		assert.is_not_nil(target)
		assert.equals("dir", target.type)
		-- Revealed but not itself expanded.
		assert.is_true(target.lazy)
	end)

	it("reveal_path returns nil for a path outside the root", function()
		helpers.populate_dir(tmpdir, { ["a"] = {} })
		buf = helpers.open_filebuf(tmpdir)
		assert.is_nil(actions.reveal_path(buf, "/etc/hosts"))
		assert.is_nil(actions.reveal_path(buf, tmpdir))
	end)

	it("reveal_path returns nil for a nonexistent path", function()
		helpers.populate_dir(tmpdir, { ["a"] = {} })
		buf = helpers.open_filebuf(tmpdir)
		assert.is_nil(actions.reveal_path(buf, tmpdir .. "/a/nope/gone.txt"))
	end)

	it("reveal_path returns nil when an ancestor is hidden and show_hidden is off", function()
		helpers.populate_dir(tmpdir, {
			[".secret"] = {},
			[".secret/inside.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		assert.is_nil(actions.reveal_path(buf, tmpdir .. "/.secret/inside.txt"))
	end)

	it("reveal_path reaches into hidden dirs when show_hidden is on", function()
		helpers.populate_dir(tmpdir, {
			[".secret"] = {},
			[".secret/inside.txt"] = "",
		})
		config.show_hidden = true
		buf = helpers.open_filebuf(tmpdir)
		local target = actions.reveal_path(buf, tmpdir .. "/.secret/inside.txt")
		assert.is_not_nil(target)
		assert.equals("inside.txt", target.name)
	end)

	it("reveal_paths reveals several targets with correct final lnums", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/one.txt"] = "",
			["z"] = {},
			["z/two.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		local found = actions.reveal_paths(buf, {
			tmpdir .. "/z/two.txt",
			tmpdir .. "/a/one.txt",
		})
		assert.equals(2, #found)
		local lines = helpers.get_buffer_lines(buf)
		-- Every returned lnum must still point at its own entry, even though
		-- the later reveal shifted nothing before it and vice versa.
		for _, e in ipairs(found) do
			assert.equals(helpers.line_set(buf)[lines[e.lnum]] and lines[e.lnum], lines[e.lnum])
			assert.is_true(lines[e.lnum]:find(e.name, 1, true) ~= nil, e.name .. " should be at lnum " .. e.lnum)
		end
	end)

	------------------------------------------------------------------
	-- Recursive expansion guard
	------------------------------------------------------------------

	it("expand_dir_recursive loads a whole subtree", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/b"] = {},
			["a/b/c"] = {},
			["a/b/c/deep.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		actions.expand_dir_recursive(buf, entry_at(buf, tmpdir .. "/a"))
		assert.same({ "a/", "  b/", "    c/", "      deep.txt" }, helpers.get_buffer_lines(buf))
	end)

	it("expand_dir_recursive asks before loading a large subtree", function()
		local structure = { ["big"] = {} }
		for i = 1, 12 do
			structure["big/file_" .. i .. ".txt"] = ""
		end
		helpers.populate_dir(tmpdir, structure)
		buf = helpers.open_filebuf(tmpdir)
		config.expand_confirm_threshold = 10

		local asked
		local real_confirm = vim.fn.confirm
		vim.fn.confirm = function(msg)
			asked = msg
			return 2 -- No
		end
		local ok, err = pcall(function()
			actions.expand_dir_recursive(buf, entry_at(buf, tmpdir .. "/big"))
		end)
		vim.fn.confirm = real_confirm
		assert.is_true(ok, tostring(err))

		assert.is_not_nil(asked, "a subtree of 12 entries should trigger the prompt")
		assert.is_true(asked:find("12 entries", 1, true) ~= nil, "prompt should state the count: " .. tostring(asked))
		-- Declined → nothing loaded.
		assert.same({ "big/" }, helpers.get_buffer_lines(buf))
		assert.is_true(entry_at(buf, tmpdir .. "/big").lazy)
	end)

	it("expand_dir_recursive proceeds when the prompt is accepted", function()
		local structure = { ["big"] = {} }
		for i = 1, 12 do
			structure["big/file_" .. i .. ".txt"] = ""
		end
		helpers.populate_dir(tmpdir, structure)
		buf = helpers.open_filebuf(tmpdir)
		config.expand_confirm_threshold = 10

		local real_confirm = vim.fn.confirm
		vim.fn.confirm = function()
			return 1 -- Yes
		end
		local ok, err = pcall(function()
			actions.expand_dir_recursive(buf, entry_at(buf, tmpdir .. "/big"))
		end)
		vim.fn.confirm = real_confirm
		assert.is_true(ok, tostring(err))

		assert.equals(13, #helpers.get_buffer_lines(buf)) -- big/ + 12 files
	end)

	it("expand_dir_recursive does not ask below the threshold", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/b"] = {},
			["a/b/deep.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		config.expand_confirm_threshold = 10

		local asked = false
		local real_confirm = vim.fn.confirm
		vim.fn.confirm = function()
			asked = true
			return 1
		end
		local ok, err = pcall(function()
			actions.expand_dir_recursive(buf, entry_at(buf, tmpdir .. "/a"))
		end)
		vim.fn.confirm = real_confirm
		assert.is_true(ok, tostring(err))

		assert.is_false(asked, "a 2-entry subtree should not prompt")
		assert.same({ "a/", "  b/", "    deep.txt" }, helpers.get_buffer_lines(buf))
	end)

	it("expand_dir_recursive never asks when the threshold is disabled", function()
		local structure = { ["big"] = {} }
		for i = 1, 12 do
			structure["big/file_" .. i .. ".txt"] = ""
		end
		helpers.populate_dir(tmpdir, structure)
		buf = helpers.open_filebuf(tmpdir)
		config.expand_confirm_threshold = false

		local asked = false
		local real_confirm = vim.fn.confirm
		vim.fn.confirm = function()
			asked = true
			return 1
		end
		local ok, err = pcall(function()
			actions.expand_dir_recursive(buf, entry_at(buf, tmpdir .. "/big"))
		end)
		vim.fn.confirm = real_confirm
		assert.is_true(ok, tostring(err))

		assert.is_false(asked)
		assert.equals(13, #helpers.get_buffer_lines(buf))
	end)

	it("expand_dir_recursive stops at max_expand_entries", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/b"] = {},
			["a/b/c"] = {},
			["a/b/c/d"] = {},
			["a/b/c/d/deep.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		config.max_expand_entries = 1 -- one child loaded, then stop
		actions.expand_dir_recursive(buf, entry_at(buf, tmpdir .. "/a"))
		-- "a" was expanded (revealing "b"), but the walk stopped there.
		assert.same({ "a/", "  b/" }, helpers.get_buffer_lines(buf))
		assert.is_true(entry_at(buf, tmpdir .. "/a/b").lazy)
	end)

	------------------------------------------------------------------
	-- Persistence across a save
	------------------------------------------------------------------

	it("keeps expanded subtrees rendered after :w", function()
		helpers.populate_dir(tmpdir, {
			["a"] = {},
			["a/b"] = {},
			["a/b/existing.txt"] = "",
		})
		buf = helpers.open_filebuf(tmpdir)
		actions.reveal_path(buf, tmpdir .. "/a/b/existing.txt")

		-- Append a new sibling file inside a/b (indent 2 → 4 spaces).
		local lines = helpers.get_buffer_lines(buf)
		lines[#lines + 1] = "      added.txt"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		helpers.save_buffer(buf)

		assert.is_not_nil(helpers.fs_stat(tmpdir .. "/a/b/added.txt"))
		-- The refresh re-expanded a and a/b rather than collapsing to top level.
		assert.same({ "a/", "  b/", "    added.txt", "    existing.txt" }, helpers.get_buffer_lines(buf))
	end)

	it("renaming an unexpanded directory preserves its unloaded subtree", function()
		helpers.populate_dir(tmpdir, {
			["olddir"] = {},
			["olddir/nested"] = {},
			["olddir/nested/deep.txt"] = "keepme",
		})
		buf = helpers.open_filebuf(tmpdir)
		-- Only "olddir/" is on screen; its children were never loaded.
		assert.same({ "olddir/" }, helpers.get_buffer_lines(buf))

		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "newdir/" })
		helpers.save_buffer(buf)

		assert.is_nil(helpers.fs_stat(tmpdir .. "/olddir"))
		assert.equals("keepme", helpers.read_file(tmpdir .. "/newdir/nested/deep.txt"))
	end)
end)
