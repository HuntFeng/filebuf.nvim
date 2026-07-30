----------------------------------------------------------------------
-- Unit tests — filebuf.snapshot, the row cache.
--
-- The snapshot holds every row find(1) returned as integer arrays plus the
-- raw output string; names are slices into that string and paths are rebuilt
-- from the parent chain on demand.  These tests drive it directly with
-- synthetic find output, so there is no filesystem involved.
--
-- Two things matter most here and are tested hardest:
--   * a projection must filter hidden/ignored entries and take their whole
--     subtree with them (this replaces the old scan.filter_visible);
--   * apply_ops must leave the rows describing exactly the tree a fresh scan
--     would produce, because a wrong path means touching the wrong file.
----------------------------------------------------------------------
local snapshot = require("filebuf.snapshot")

local ROOT = "/root"

--- Build find(1)-shaped output from a compact spec.
--- Each item is { depth, type, name, mtime?, ctime? } where type is "d" | "f" | "l".
--- The format matches: find ... -printf "%d\\t%y\\t%T@\\t%C@\\t%f\\n"
---@param rows table[]
---@return string
local function find_output(rows)
	local parts = {}
	for _, r in ipairs(rows) do
		parts[#parts + 1] = string.format("%d\t%s\t%d.0\t%d.0\t%s\n", r[1], r[2], r[4] or 0, r[5] or 0, r[3])
	end
	return table.concat(parts)
end

--- A built snapshot over `rows`, projected with `opts`.
---@param rows table[]
---@param opts? table  { show_hidden?, method?, ignore_set?, maxdepth?, pruned? }
---@return table snap
local function build(rows, opts)
	opts = opts or {}
	local snap = snapshot.new(ROOT)
	snapshot.build(snap, find_output(rows), opts.maxdepth or 20, opts.ignore_set, opts.pruned or false)
	snapshot.project(snap, opts.method or "type", opts.show_hidden or false)
	return snap
end

--- The names of the visible rows, in display order.
local function visible_names(snap)
	local out = {}
	for lnum = 1, #snap.view do
		out[lnum] = snapshot.name(snap, snap.view[lnum])
	end
	return out
end

-- A small tree reused across tests:
--   dir/           d 1
--     nested/      d 2
--       deep.txt   f 3
--     a.txt        f 2
--   .hidden/       d 1
--     inside.txt   f 2
--   .dotfile       f 1
--   zeta.txt       f 1
--   link@          l 1
local TREE = {
	{ 1, "d", "dir" },
	{ 2, "d", "nested" },
	{ 3, "f", "deep.txt" },
	{ 2, "f", "a.txt" },
	{ 1, "d", ".hidden" },
	{ 2, "f", "inside.txt" },
	{ 1, "f", ".dotfile" },
	{ 1, "f", "zeta.txt" },
	{ 1, "l", "link" },
}

describe("snapshot.build", function()
	it("records one row per find output line", function()
		local snap = build(TREE)
		assert.equals(#TREE, snap.n)
	end)

	it("derives names as slices of the retained output", function()
		local snap = build(TREE)
		assert.equals("dir", snapshot.name(snap, 1))
		assert.equals("deep.txt", snapshot.name(snap, 3))
		assert.equals("link", snapshot.name(snap, 9))
		-- No per-row name strings are stored; overrides only appear after a save.
		assert.is_nil(snap.names)
	end)

	it("maps find depth to zero-based indent", function()
		local snap = build(TREE)
		assert.equals(0, snap.indent[1]) -- dir at depth 1
		assert.equals(1, snap.indent[2]) -- nested at depth 2
		assert.equals(2, snap.indent[3]) -- deep.txt at depth 3
	end)

	it("classifies dirs, files and links", function()
		local snap = build(TREE)
		assert.equals("dir", snapshot.type(snap, 1))
		assert.equals("file", snapshot.type(snap, 3))
		assert.equals("link", snapshot.type(snap, 9))
		assert.is_true(snapshot.is_dir(snap, 1))
		assert.is_false(snapshot.is_dir(snap, 3))
	end)

	it("links each row to its parent row", function()
		local snap = build(TREE)
		assert.equals(0, snap.parent[1]) -- dir -> root
		assert.equals(1, snap.parent[2]) -- nested -> dir
		assert.equals(2, snap.parent[3]) -- deep.txt -> nested
		assert.equals(1, snap.parent[4]) -- a.txt -> dir
		assert.equals(0, snap.parent[8]) -- zeta.txt -> root
	end)

	it("flags dot-prefixed names as hidden", function()
		local snap = build(TREE)
		assert.is_true(snapshot.has_flag(snap, 5, snapshot.F_HIDDEN)) -- .hidden
		assert.is_true(snapshot.has_flag(snap, 7, snapshot.F_HIDDEN)) -- .dotfile
		assert.is_false(snapshot.has_flag(snap, 1, snapshot.F_HIDDEN)) -- dir
	end)

	it("flags gitignored paths from the ignore set", function()
		local snap = build(TREE, { ignore_set = { [ROOT .. "/zeta.txt"] = true } })
		assert.is_true(snapshot.has_flag(snap, 8, snapshot.F_IGNORED))
		assert.is_false(snapshot.has_flag(snap, 1, snapshot.F_IGNORED))
	end)

	it("only flags an ignored path when the full path matches, not just the name", function()
		-- The ignore check is gated on a basename index for speed; a same-named
		-- entry elsewhere in the tree must not inherit the flag.
		local snap = build({
			{ 1, "d", "a" },
			{ 2, "f", "target.txt" },
			{ 1, "d", "b" },
			{ 2, "f", "target.txt" },
		}, { ignore_set = { [ROOT .. "/a/target.txt"] = true } })
		assert.is_true(snapshot.has_flag(snap, 2, snapshot.F_IGNORED))
		assert.is_false(snapshot.has_flag(snap, 4, snapshot.F_IGNORED))
	end)

	it("flags directories at maxdepth as truncated", function()
		local snap = build(TREE, { maxdepth = 2 })
		-- nested sits at depth 2 == maxdepth, so its children were never listed.
		assert.is_true(snapshot.has_flag(snap, 2, snapshot.F_TRUNCATED))
		assert.is_false(snapshot.has_flag(snap, 1, snapshot.F_TRUNCATED))
		assert.is_true(snapshot.truncated_paths(snap)[ROOT .. "/dir/nested"])
	end)

	it("resets name overrides when rebuilt", function()
		local snap = build(TREE)
		snap.names = { [1] = "stale" }
		snapshot.build(snap, find_output(TREE), 20, nil, false)
		assert.is_nil(snap.names)
	end)

	it("handles empty output", function()
		local snap = build({})
		assert.equals(0, snap.n)
		assert.same({}, visible_names(snap))
	end)
end)

describe("snapshot.path_of", function()
	it("rebuilds an absolute path from the parent chain", function()
		local snap = build(TREE)
		assert.equals(ROOT .. "/dir", snapshot.path_of(snap, 1))
		assert.equals(ROOT .. "/dir/nested", snapshot.path_of(snap, 2))
		assert.equals(ROOT .. "/dir/nested/deep.txt", snapshot.path_of(snap, 3))
		assert.equals(ROOT .. "/.hidden/inside.txt", snapshot.path_of(snap, 6))
	end)

	it("round-trips through row_of_path for every row", function()
		local snap = build(TREE, { show_hidden = true })
		for row = 1, snap.n do
			assert.equals(row, snapshot.row_of_path(snap, snapshot.path_of(snap, row)))
		end
	end)

	it("returns nil for paths outside the tree", function()
		local snap = build(TREE)
		assert.is_nil(snapshot.row_of_path(snap, "/elsewhere/x"))
		assert.is_nil(snapshot.row_of_path(snap, ROOT))
		assert.is_nil(snapshot.row_of_path(snap, ROOT .. "/nope"))
	end)

	it("maps a path to its buffer line, or nil when not displayed", function()
		local snap = build(TREE)
		assert.equals(1, snapshot.lnum_of_path(snap, ROOT .. "/dir"))
		-- .hidden is filtered out of this projection.
		assert.is_nil(snapshot.lnum_of_path(snap, ROOT .. "/.hidden"))
	end)
end)

describe("snapshot.project", function()
	it("hides dot-prefixed entries when show_hidden is off", function()
		local snap = build(TREE, { show_hidden = false })
		assert.same({ "dir", "nested", "deep.txt", "a.txt", "link", "zeta.txt" }, visible_names(snap))
	end)

	it("shows everything when show_hidden is on", function()
		local snap = build(TREE, { show_hidden = true })
		assert.equals(#TREE, #snap.view)
	end)

	it("takes the whole subtree of a hidden directory with it", function()
		local snap = build(TREE, { show_hidden = false })
		-- inside.txt is not itself hidden, but its parent is.
		assert.is_nil(snapshot.lnum_of_path(snap, ROOT .. "/.hidden/inside.txt"))
	end)

	it("excludes an ignored directory's subtree too", function()
		local snap = build({
			{ 1, "d", "build" },
			{ 2, "f", "out.o" },
			{ 1, "f", "keep.txt" },
		}, { ignore_set = { [ROOT .. "/build"] = true } })
		assert.same({ "keep.txt" }, visible_names(snap))
	end)

	it("orders dirs, then links, then files with sort_method type", function()
		local snap = build(TREE, { method = "type", show_hidden = false })
		assert.same({ "dir", "nested", "deep.txt", "a.txt", "link", "zeta.txt" }, visible_names(snap))
	end)

	it("orders purely by name with sort_method name", function()
		local snap = build(TREE, { method = "name", show_hidden = false })
		-- a.txt sorts before nested inside dir/; link before zeta at top level.
		assert.same({ "dir", "a.txt", "nested", "deep.txt", "link", "zeta.txt" }, visible_names(snap))
	end)

	it("sorts case-insensitively", function()
		local snap = build({
			{ 1, "f", "Beta.txt" },
			{ 1, "f", "alpha.txt" },
			{ 1, "f", "Gamma.txt" },
		}, { method = "name" })
		assert.same({ "alpha.txt", "Beta.txt", "Gamma.txt" }, visible_names(snap))
	end)

	it("keeps every subtree glued beneath its parent", function()
		local snap = build({
			{ 1, "d", "zzz" },
			{ 2, "f", "inside_z.txt" },
			{ 1, "d", "aaa" },
			{ 2, "f", "inside_a.txt" },
		}, { method = "name" })
		assert.same({ "aaa", "inside_a.txt", "zzz", "inside_z.txt" }, visible_names(snap))
	end)

	it("gives view and row_of as mutual inverses", function()
		local snap = build(TREE, { show_hidden = true })
		for lnum = 1, #snap.view do
			assert.equals(lnum, snap.row_of[snap.view[lnum]])
		end
	end)

	it("is stable across repeated flips of show_hidden", function()
		-- Sibling order is memoised per range and only computed for ranges the
		-- walk reaches, so flipping must not disturb what was already ordered.
		local snap = build(TREE, { show_hidden = false })
		local first = table.concat(visible_names(snap), ",")
		for _ = 1, 3 do
			snapshot.project(snap, "type", true)
			snapshot.project(snap, "type", false)
		end
		assert.equals(first, table.concat(visible_names(snap), ","))
	end)

	it("re-orders when the sort method changes", function()
		local snap = build(TREE, { method = "type" })
		snapshot.project(snap, "name", false)
		assert.same({ "dir", "a.txt", "nested", "deep.txt", "link", "zeta.txt" }, visible_names(snap))
	end)

	it("keeps find's order for methods with no comparator", function()
		local snap = build(TREE, {})
		assert.same({ "dir", "nested", "deep.txt", "a.txt", "link", "zeta.txt" }, visible_names(snap))
	end)
end)

describe("snapshot.lines", function()
	before_each(function()
		vim.go.expandtab = true
		vim.go.shiftwidth = 2
	end)

	it("indents by level and marks dirs and links", function()
		local snap = build(TREE, { show_hidden = false })
		assert.same({
			"dir/",
			"  nested/",
			"    deep.txt",
			"  a.txt",
			"link@",
			"zeta.txt",
		}, snapshot.lines(snap))
	end)

	it("honours shiftwidth", function()
		vim.go.shiftwidth = 4
		local snap = build({ { 1, "d", "d" }, { 2, "f", "f.txt" } })
		assert.same({ "d/", "    f.txt" }, snapshot.lines(snap))
	end)

	it("indents with tabs when expandtab is off", function()
		vim.go.expandtab = false
		local snap = build({ { 1, "d", "d" }, { 2, "f", "f.txt" } })
		assert.same({ "d/", "\tf.txt" }, snapshot.lines(snap))
		vim.go.expandtab = true
	end)

	it("escapes control characters in names", function()
		local snap = build({ { 1, "f", "we\rird.txt" } })
		assert.same({ "we$'\\r'ird.txt" }, snapshot.lines(snap))
	end)
end)

describe("snapshot.apply_ops", function()
	--- Ops in the shape compute_diff returns.
	local function ops(t)
		return {
			created = t.created or {},
			deleted = t.deleted or {},
			renamed = t.renamed or {},
			unchanged = {},
			errors = {},
		}
	end
	local function entry(path, etype)
		return { path = path, name = path:match("[^/]+$"), type = etype or "file" }
	end

	it("appends a created file under its parent", function()
		local snap = build(TREE)
		assert.is_true(snapshot.apply_ops(snap, ops({ created = { entry(ROOT .. "/new.txt") } }), nil))
		snapshot.project(snap, "type", false)
		assert.equals(#TREE + 1, snap.n)
		assert.is_not_nil(snapshot.lnum_of_path(snap, ROOT .. "/new.txt"))
	end)

	it("appends a created nested file with the right indent", function()
		local snap = build(TREE)
		snapshot.apply_ops(snap, ops({ created = { entry(ROOT .. "/dir/nested/extra.txt") } }), nil)
		snapshot.project(snap, "type", false)
		local row = snapshot.row_of_path(snap, ROOT .. "/dir/nested/extra.txt")
		assert.is_not_nil(row)
		assert.equals(2, snap.indent[row])
	end)

	it("creates a directory and a child of it in one call", function()
		local snap = build(TREE)
		assert.is_true(
			snapshot.apply_ops(
				snap,
				ops({ created = { entry(ROOT .. "/fresh/kid.txt"), entry(ROOT .. "/fresh", "dir") } }),
				nil
			)
		)
		snapshot.project(snap, "type", false)
		assert.is_not_nil(snapshot.lnum_of_path(snap, ROOT .. "/fresh"))
		assert.is_not_nil(snapshot.lnum_of_path(snap, ROOT .. "/fresh/kid.txt"))
	end)

	it("flags a created hidden file as hidden", function()
		local snap = build(TREE)
		snapshot.apply_ops(snap, ops({ created = { entry(ROOT .. "/.newdot") } }), nil)
		snapshot.project(snap, "type", false)
		assert.is_nil(snapshot.lnum_of_path(snap, ROOT .. "/.newdot"))
		snapshot.project(snap, "type", true)
		assert.is_not_nil(snapshot.lnum_of_path(snap, ROOT .. "/.newdot"))
	end)

	it("drops a deleted file", function()
		local snap = build(TREE)
		assert.is_true(snapshot.apply_ops(snap, ops({ deleted = { entry(ROOT .. "/zeta.txt") } }), nil))
		snapshot.project(snap, "type", false)
		assert.is_nil(snapshot.lnum_of_path(snap, ROOT .. "/zeta.txt"))
	end)

	it("drops a deleted directory's whole subtree", function()
		local snap = build(TREE)
		snapshot.apply_ops(snap, ops({ deleted = { entry(ROOT .. "/dir", "dir") } }), nil)
		snapshot.project(snap, "type", true)
		assert.is_nil(snapshot.lnum_of_path(snap, ROOT .. "/dir"))
		assert.is_nil(snapshot.lnum_of_path(snap, ROOT .. "/dir/nested"))
		assert.is_nil(snapshot.lnum_of_path(snap, ROOT .. "/dir/nested/deep.txt"))
	end)

	it("renames a file in place", function()
		local snap = build(TREE)
		assert.is_true(
			snapshot.apply_ops(
				snap,
				ops({ renamed = { { old = entry(ROOT .. "/zeta.txt"), new = entry(ROOT .. "/omega.txt") } } }),
				nil
			)
		)
		snapshot.project(snap, "type", false)
		assert.is_nil(snapshot.lnum_of_path(snap, ROOT .. "/zeta.txt"))
		assert.is_not_nil(snapshot.lnum_of_path(snap, ROOT .. "/omega.txt"))
	end)

	it("re-points a renamed directory's whole subtree", function()
		-- Paths are derived from the parent chain, so descendants follow with no
		-- per-row fixing.
		local snap = build(TREE)
		snapshot.apply_ops(
			snap,
			ops({ renamed = { { old = entry(ROOT .. "/dir", "dir"), new = entry(ROOT .. "/renamed", "dir") } } }),
			nil
		)
		snapshot.project(snap, "type", false)
		assert.is_not_nil(snapshot.lnum_of_path(snap, ROOT .. "/renamed/nested/deep.txt"))
		assert.is_nil(snapshot.lnum_of_path(snap, ROOT .. "/dir/nested/deep.txt"))
	end)

	it("shifts indents when a row moves to a different parent", function()
		local snap = build(TREE)
		snapshot.apply_ops(
			snap,
			ops({
				renamed = { { old = entry(ROOT .. "/dir/a.txt"), new = entry(ROOT .. "/a.txt") } },
			}),
			nil
		)
		snapshot.project(snap, "type", false)
		local row = snapshot.row_of_path(snap, ROOT .. "/a.txt")
		assert.is_not_nil(row)
		assert.equals(0, snap.indent[row])
	end)

	it("re-flags a file renamed to a hidden name", function()
		local snap = build(TREE)
		snapshot.apply_ops(
			snap,
			ops({ renamed = { { old = entry(ROOT .. "/zeta.txt"), new = entry(ROOT .. "/.zeta.txt") } } }),
			nil
		)
		snapshot.project(snap, "type", false)
		assert.is_nil(snapshot.lnum_of_path(snap, ROOT .. "/.zeta.txt"))
		snapshot.project(snap, "type", true)
		assert.is_not_nil(snapshot.lnum_of_path(snap, ROOT .. "/.zeta.txt"))
	end)

	it("applies creates, deletes and renames together", function()
		local snap = build(TREE)
		assert.is_true(snapshot.apply_ops(
			snap,
			ops({
				created = { entry(ROOT .. "/added.txt") },
				deleted = { entry(ROOT .. "/dir/a.txt") },
				renamed = { { old = entry(ROOT .. "/zeta.txt"), new = entry(ROOT .. "/zed.txt") } },
			}),
			nil
		))
		snapshot.project(snap, "type", false)
		assert.is_not_nil(snapshot.lnum_of_path(snap, ROOT .. "/added.txt"))
		assert.is_nil(snapshot.lnum_of_path(snap, ROOT .. "/dir/a.txt"))
		assert.is_not_nil(snapshot.lnum_of_path(snap, ROOT .. "/zed.txt"))
	end)

	it("declines when an op refers to a path it does not hold", function()
		local snap = build(TREE)
		assert.is_false(snapshot.apply_ops(snap, ops({ deleted = { entry(ROOT .. "/ghost.txt") } }), nil))
	end)

	it("declines nested cross-parent moves rather than guess", function()
		-- Both dir and dir/nested move to a new parent; shifting one subtree
		-- would shift the other twice.
		local snap = build({
			{ 1, "d", "top" },
			{ 2, "d", "mid" },
			{ 3, "f", "leaf.txt" },
			{ 1, "d", "other" },
		})
		local declined = snapshot.apply_ops(
			snap,
			ops({
				renamed = {
					{ old = entry(ROOT .. "/top", "dir"), new = entry(ROOT .. "/other/top", "dir") },
					{ old = entry(ROOT .. "/top/mid", "dir"), new = entry(ROOT .. "/other/mid", "dir") },
				},
			}),
			nil
		)
		assert.is_false(declined)
	end)

	it("leaves no stale projection behind when it declines", function()
		local snap = build(TREE)
		assert.is_not_nil(snap.view)
		snapshot.apply_ops(snap, ops({ deleted = { entry(ROOT .. "/ghost.txt") } }), nil)
		assert.is_nil(snap.view)
		assert.is_nil(snap.row_of)
	end)

	it("keeps path lookups working for rows it added", function()
		local snap = build(TREE)
		snapshot.apply_ops(snap, ops({ created = { entry(ROOT .. "/added.txt") } }), nil)
		snapshot.project(snap, "type", false)
		for lnum = 1, #snap.view do
			local row = snap.view[lnum]
			assert.equals(row, snapshot.row_of_path(snap, snapshot.path_of(snap, row)))
		end
	end)
end)
