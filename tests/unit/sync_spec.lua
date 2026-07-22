----------------------------------------------------------------------
-- Unit tests for sync.lua — diff computation (compute_diff).
-- Tests the three-phase diff algorithm with mock entry tables.
----------------------------------------------------------------------
local sync = require("filebuf.sync")

-- Helper: build a synthetic entry table (minimal fields).
local function entry(name, etype, path, indent, lnum)
	return { name = name, type = etype, path = path, indent = indent or 0, lnum = lnum or 1 }
end

describe("sync.lua", function()
	describe("compute_diff", function()
		------------------------------------------------------------------
		-- No changes
		------------------------------------------------------------------
		it("reports no changes when buffer matches disk exactly", function()
			local disk = {
				entry("a.txt", "file", "/root/a.txt", 0, 1),
				entry("sub", "dir", "/root/sub", 0, 2),
				entry("b.txt", "file", "/root/sub/b.txt", 1, 3),
			}
			local buf = {
				entry("a.txt", "file", "/root/a.txt", 0, 1),
				entry("sub", "dir", "/root/sub", 0, 2),
				entry("b.txt", "file", "/root/sub/b.txt", 1, 3),
			}
			local ops = sync.compute_diff(buf, disk)
			assert.equals(3, #ops.unchanged)
			assert.equals(0, #ops.created)
			assert.equals(0, #ops.deleted)
			assert.equals(0, #ops.renamed)
			assert.equals(0, #ops.errors)
		end)

		it("returns empty ops for empty input", function()
			local ops = sync.compute_diff({}, {})
			assert.equals(0, #ops.unchanged)
			assert.equals(0, #ops.created)
			assert.equals(0, #ops.deleted)
			assert.equals(0, #ops.renamed)
			assert.equals(0, #ops.errors)
		end)

		------------------------------------------------------------------
		-- Creates
		------------------------------------------------------------------
		it("detects a new file entry as created", function()
			local disk = { entry("a.txt", "file", "/root/a.txt", 0, 1) }
			local buf = {
				entry("a.txt", "file", "/root/a.txt", 0, 1),
				entry("new.txt", "file", "/root/new.txt", 0, 2),
			}
			local ops = sync.compute_diff(buf, disk)
			assert.equals(1, #ops.created)
			assert.equals("new.txt", ops.created[1].name)
			assert.equals("file", ops.created[1].type)
		end)

		it("detects a new directory entry as created", function()
			local disk = { entry("a.txt", "file", "/root/a.txt", 0, 1) }
			local buf = {
				entry("a.txt", "file", "/root/a.txt", 0, 1),
				entry("newdir", "dir", "/root/newdir", 0, 2),
			}
			local ops = sync.compute_diff(buf, disk)
			assert.equals(1, #ops.created)
			assert.equals("newdir", ops.created[1].name)
			assert.equals("dir", ops.created[1].type)
		end)

		it("detects nested file creation (indented under existing dir)", function()
			local disk = {
				entry("sub", "dir", "/root/sub", 0, 1),
			}
			local buf = {
				entry("sub", "dir", "/root/sub", 0, 1),
				entry("new.txt", "file", "/root/sub/new.txt", 1, 2),
			}
			local ops = sync.compute_diff(buf, disk)
			assert.equals(1, #ops.unchanged) -- sub is the only unchanged entry
			assert.equals(1, #ops.created)
			assert.equals("new.txt", ops.created[1].name)
			assert.equals("/root/sub/new.txt", ops.created[1].path)
		end)

		it("detects multiple creates in one diff", function()
			local disk = { entry("a.txt", "file", "/root/a.txt", 0, 1) }
			local buf = {
				entry("a.txt", "file", "/root/a.txt", 0, 1),
				entry("b.txt", "file", "/root/b.txt", 0, 2),
				entry("c.txt", "file", "/root/c.txt", 0, 3),
			}
			local ops = sync.compute_diff(buf, disk)
			assert.equals(2, #ops.created)
		end)

		------------------------------------------------------------------
		-- Deletes
		------------------------------------------------------------------
		it("detects a missing file entry as deleted", function()
			local disk = {
				entry("a.txt", "file", "/root/a.txt", 0, 1),
				entry("b.txt", "file", "/root/b.txt", 0, 2),
			}
			local buf = { entry("a.txt", "file", "/root/a.txt", 0, 1) }
			local ops = sync.compute_diff(buf, disk)
			assert.equals(1, #ops.deleted)
			assert.equals("b.txt", ops.deleted[1].name)
		end)

		it("detects a missing directory as deleted", function()
			local disk = {
				entry("sub", "dir", "/root/sub", 0, 1),
				entry("a.txt", "file", "/root/a.txt", 0, 2),
			}
			local buf = { entry("a.txt", "file", "/root/a.txt", 0, 1) }
			local ops = sync.compute_diff(buf, disk)
			assert.equals(1, #ops.deleted)
			assert.equals("sub", ops.deleted[1].name)
			assert.equals("dir", ops.deleted[1].type)
		end)

		it("detects both a dir and its children as deleted", function()
			local disk = {
				entry("sub", "dir", "/root/sub", 0, 1),
				entry("nested.txt", "file", "/root/sub/nested.txt", 1, 2),
			}
			local buf = {}
			local ops = sync.compute_diff(buf, disk)
			assert.equals(2, #ops.deleted)
		end)

		------------------------------------------------------------------
		-- Renames
		------------------------------------------------------------------
		it("detects a simple rename (same name, different parent)", function()
			local disk = { entry("file.txt", "file", "/root/old/file.txt", 1, 1) }
			local buf = { entry("file.txt", "file", "/root/new/file.txt", 1, 1) }
			local ops = sync.compute_diff(buf, disk)
			assert.equals(1, #ops.renamed)
			assert.equals("/root/old/file.txt", ops.renamed[1].old.path)
			assert.equals("/root/new/file.txt", ops.renamed[1].new.path)
		end)

		it("detects a rename of a directory", function()
			local disk = { entry("olddir", "dir", "/root/olddir", 0, 1) }
			local buf = { entry("newdir", "dir", "/root/newdir", 0, 1) }
			-- Actually, with different names this would be delete+create.
			-- Rename detection is name-based, so same-name is renamed.
			local ops = sync.compute_diff(buf, disk)
			-- Not same name → olddir is deleted, newdir is created.
			assert.equals(1, #ops.deleted)
			assert.equals("olddir", ops.deleted[1].name)
			assert.equals(1, #ops.created)
			assert.equals("newdir", ops.created[1].name)
		end)

		it("detects a name-based rename (same name, same parent)", function()
			-- When the buffer has same name but different path, it's a rename.
			-- Actually same name + same parent = unchanged by exact-path match.
			-- Different parent = rename.
			local disk = {
				entry("file.txt", "file", "/root/a/file.txt", 1, 1),
			}
			local buf = {
				entry("file.txt", "file", "/root/b/file.txt", 1, 1),
			}
			local ops = sync.compute_diff(buf, disk)
			assert.equals(1, #ops.renamed)
			assert.equals("/root/a/file.txt", ops.renamed[1].old.path)
			assert.equals("/root/b/file.txt", ops.renamed[1].new.path)
		end)

		it("prefers same-parent match when multiple same-name candidates exist", function()
			local disk = {
				entry("file.txt", "file", "/root/a/file.txt", 1, 1),
				entry("file.txt", "file", "/root/sub/file.txt", 1, 2),
			}
			local buf = {
				entry("file.txt", "file", "/root/sub/file_renamed.txt", 1, 1),
			}
			local ops = sync.compute_diff(buf, disk)
			-- The buffer entry at /root/sub/file_renamed.txt matches:
			-- 1. /root/sub/file.txt (same parent /root/sub) — preferred!
			-- 2. /root/a/file.txt (fallback)
			assert.equals(1, #ops.renamed)
			assert.equals("/root/sub/file.txt", ops.renamed[1].old.path)
			-- /root/a/file.txt is deleted (unmatched)
			assert.equals(1, #ops.deleted)
			assert.equals("/root/a/file.txt", ops.deleted[1].path)
		end)

		------------------------------------------------------------------
		-- Complex scenarios
		------------------------------------------------------------------
		it("handles a mix of creates, renames, and deletes", function()
			local disk = {
				entry("keep.txt", "file", "/root/keep.txt", 0, 1),
				entry("move.txt", "file", "/root/old/move.txt", 1, 2),
				entry("remove.txt", "file", "/root/remove.txt", 0, 3),
			}
			local buf = {
				entry("keep.txt", "file", "/root/keep.txt", 0, 1),
				entry("move.txt", "file", "/root/new/move.txt", 1, 2),
				entry("added.txt", "file", "/root/added.txt", 0, 3),
			}
			local ops = sync.compute_diff(buf, disk)
			-- keep.txt → unchanged
			assert.equals(1, #ops.unchanged)
			assert.equals("keep.txt", ops.unchanged[1].name)
			-- move.txt → renamed
			assert.equals(1, #ops.renamed)
			assert.equals("move.txt", ops.renamed[1].old.name)
			assert.equals("/root/new/move.txt", ops.renamed[1].new.path)
			-- added.txt → created
			assert.equals(1, #ops.created)
			assert.equals("added.txt", ops.created[1].name)
			-- remove.txt → deleted
			assert.equals(1, #ops.deleted)
			assert.equals("remove.txt", ops.deleted[1].name)
			assert.equals(0, #ops.errors)
		end)

		------------------------------------------------------------------
		-- Type mismatch errors
		------------------------------------------------------------------
		it("flags an error when a file is changed to a directory", function()
			local disk = { entry("foo", "file", "/root/foo", 0, 1) }
			local buf = { entry("foo", "dir", "/root/foo", 0, 1) }
			local ops = sync.compute_diff(buf, disk)
			assert.equals(1, #ops.errors)
			-- string.find returns a start position (number), which is truthy.
			assert.is_not_nil(ops.errors[1].message:find("file on disk"))
		end)

		it("flags an error when a directory is changed to a file", function()
			local disk = { entry("bar", "dir", "/root/bar", 0, 1) }
			local buf = { entry("bar", "file", "/root/bar", 0, 1) }
			local ops = sync.compute_diff(buf, disk)
			assert.equals(1, #ops.errors)
			assert.is_not_nil(ops.errors[1].message:find("dir on disk"))
		end)

		it("flags an error on type mismatch during rename", function()
			local disk = { entry("item", "file", "/root/old/item", 1, 1) }
			local buf = { entry("item", "dir", "/root/new/item", 1, 1) }
			local ops = sync.compute_diff(buf, disk)
			assert.equals(1, #ops.errors)
			assert.is_not_nil(ops.errors[1].message:find("Type changes"))
		end)

		it("includes line number in error messages", function()
			local disk = { entry("foo", "file", "/root/foo", 0, 1) }
			local buf = { entry("foo", "dir", "/root/foo", 0, 5) }
			local ops = sync.compute_diff(buf, disk)
			assert.equals(1, #ops.errors)
			assert.equals(5, ops.errors[1].lnum)
		end)

		it("records both an error and unchanged for type-mismatched entries", function()
			-- The entry at the same path is still recorded as unchanged (it occupies
			-- the same slot); the error is reported separately.
			local disk = { entry("foo", "file", "/root/foo", 0, 1) }
			local buf = { entry("foo", "dir", "/root/foo", 0, 1) }
			local ops = sync.compute_diff(buf, disk)
			assert.equals(1, #ops.unchanged)
			assert.equals(1, #ops.errors)
		end)
	end)
end)
