----------------------------------------------------------------------
-- Yank / paste (copy) support.
--
-- Buffer text carries no identity, so "this new line is a copy of that
-- entry" cannot be expressed by the text alone.  Two pieces of state fill
-- the gap, both living on the buffer state:
--
--   st.clipboard    the yanked source entries.
--   st.copy_targets extmark id → source, for the lines a paste inserted.
--                   Real (non-ephemeral) extmarks, so the binding follows
--                   the line as the user edits above it — and survives
--                   renaming the pasted line, which is mandatory when
--                   copying into the source's own directory.
--
-- On :w the marked lines are pulled out of the buffer entry list before
-- the diff runs (see filebuf.init.save_buffer) and applied as explicit
-- copy operations.  Leaving them in would let the diff's rename phases
-- pair a pasted line with an unrelated same-named disk entry and turn the
-- copy into a move.
----------------------------------------------------------------------
local line_mod = require("filebuf.line")
local state = require("filebuf.state")

local M = {}

--- Namespace for paste-target marks.  Deliberately separate from
--- filebuf-deco, whose marks are all ephemeral.
M.ns = vim.api.nvim_create_namespace("filebuf-copy")

--- Namespace for the transient yank/paste flash, kept apart from M.ns so
--- the flash's short-lived highlight can never be mistaken for a
--- copy_targets mark by M.pending().
local flash_ns = vim.api.nvim_create_namespace("filebuf-copy-flash")

--- Flash lines `lo`..`hi` with FilebufCopyMark, the way Neovim's native
--- TextYankPost handler flashes a real yank.
---@param buf number
---@param lo  number 1-based, inclusive
---@param hi  number 1-based, inclusive
local function flash(buf, lo, hi)
	local hl = vim.hl or vim.highlight
	hl.range(buf, flash_ns, "FilebufCopyMark", { lo - 1, 0 }, { hi - 1, 0 }, {
		regtype = "V",
		inclusive = true,
		timeout = 300,
	})
end

--- Last line of the visible subtree rooted at the directory on line `lnum`
--- (indent `indent`).  A closed child fold is skipped over via
--- foldclosedend instead of walked line by line, so the cost is bounded by
--- what's already on screen under the directory — the same lines a redraw
--- already pays for — never a whole-tree walk.
---@param resolve fun(lnum: number): table|nil  from state.range_resolver
---@param lnum    number  the directory's own line
---@param indent  number  the directory's indent level
---@return number
local function subtree_end(resolve, lnum, indent)
	local last, probe = lnum, lnum + 1
	while true do
		local entry = resolve(probe)
		if not entry or entry.indent <= indent then
			return last
		end
		local closed_end = vim.fn.foldclosedend(probe)
		last = closed_end ~= -1 and closed_end or probe
		probe = last + 1
	end
end

--- True when `path` is at or below `dir`.
---@param path string
---@param dir  string
---@return boolean
local function under(path, dir)
	return path:sub(1, #dir + 1) == dir .. "/"
end

----------------------------------------------------------------------
-- Clipboard
----------------------------------------------------------------------

--- Whether `path` is yanked — either listed outright, or a descendant of a
--- yanked directory.  Descendants count because a directory copy is
--- recursive, so they really are part of what will be copied.
---@param st   table   buffer state
---@param path string
---@return boolean
function M.is_marked(st, path)
	local clip = st and st.clipboard
	if not clip or #clip == 0 then
		return false
	end
	if clip.paths[path] then
		return true
	end
	for _, src in ipairs(clip) do
		if src.type == "dir" and under(path, src.path) then
			return true
		end
	end
	return false
end

--- Yank the entries on lines `lo`..`hi` into the clipboard.
---
--- Entries nested under another selected directory are dropped: the
--- directory copy already carries them, and copying them again would mean
--- a second, redundant filesystem walk.
---
--- Yanking exactly what is already yanked clears the clipboard, so gy on a
--- marked entry unmarks it.
---@param buf number
---@param lo  number  1-based, inclusive
---@param hi  number  1-based, inclusive
function M.yank(buf, lo, hi)
	local st = state.get(buf)
	if not st then
		return
	end

	local resolve = state.range_resolver(buf)
	local picked, paths = {}, {}
	local last_entry
	for lnum = lo, hi do
		local entry = resolve(lnum)
		if entry then
			last_entry = entry
			local nested = false
			for _, p in ipairs(picked) do
				if p.type == "dir" and under(entry.path, p.path) then
					nested = true
					break
				end
			end
			if not nested and not paths[entry.path] then
				picked[#picked + 1] = { path = entry.path, name = entry.name, type = entry.type }
				paths[entry.path] = true
			end
		end
	end

	if #picked == 0 then
		return
	end

	-- Re-yanking the identical selection is an unmark.
	local clip = st.clipboard
	if clip and #clip == #picked then
		local same = true
		for _, p in ipairs(picked) do
			if not clip.paths[p.path] then
				same = false
				break
			end
		end
		if same then
			M.clear(buf)
			vim.notify("filebuf: yank cleared", vim.log.levels.INFO)
			return
		end
	end

	picked.paths = paths
	st.clipboard = picked
	-- A directory at the tail of the selection marks its children too
	-- (M.is_marked), so the flash should cover whatever of them is visible.
	local flash_hi = hi
	if last_entry and last_entry.type == "dir" then
		flash_hi = subtree_end(resolve, hi, last_entry.indent)
	end
	flash(buf, lo, flash_hi)
	vim.notify(
		string.format("filebuf: yanked %d %s", #picked, #picked == 1 and "entry" or "entries"),
		vim.log.levels.INFO
	)
end

--- Yank the entry under the cursor.
---@param buf number
function M.yank_at_cursor(buf)
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	M.yank(buf, lnum, lnum)
end

--- Drop the clipboard and every paste-target mark for `buf`.
---@param buf number
function M.clear(buf)
	local st = state.get(buf)
	if st then
		st.clipboard = nil
		st.copy_targets = nil
	end
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
		vim.api.nvim_buf_clear_namespace(buf, flash_ns, 0, -1)
	end
end

----------------------------------------------------------------------
-- Paste
----------------------------------------------------------------------

--- Insert a line per clipboard entry at the cursor and bind each one to
--- its source.
---
--- Only the top-level lines go in: the children of a pasted directory come
--- from the recursive copy on :w and appear in the re-render after it.
--- Inserting them here would leave the diff unable to tell a child that
--- rode along with the copy from one the user typed.
---@param buf number
function M.paste(buf)
	local st = state.get(buf)
	if not st then
		return
	end
	local clip = st.clipboard
	if not clip or #clip == 0 then
		vim.notify("filebuf: nothing yanked", vim.log.levels.WARN)
		return
	end

	-- A directory under the cursor receives the paste as its first child;
	-- anything else pastes as a sibling.  Indent alone decides nesting, so
	-- this is correct even when the directory's fold is closed.
	local entry = state.entry_at_cursor(buf)
	local at, indent
	if entry then
		at = entry.lnum
		indent = entry.type == "dir" and entry.indent + 1 or entry.indent
	else
		at, indent = 0, 0
	end

	local prefix = line_mod.indent_str(indent)
	local lines = {}
	for i, src in ipairs(clip) do
		local suffix = src.type == "dir" and "/" or (src.type == "link" and "@" or "")
		lines[i] = prefix .. src.name .. suffix
	end
	vim.api.nvim_buf_set_lines(buf, at, at, false, lines)

	st.copy_targets = st.copy_targets or {}
	for i, src in ipairs(clip) do
		-- Left gravity: replacing the whole line (`cc`, or a set_lines rewrite)
		-- would otherwise push a mark sitting at column 0 onto the following
		-- line, and renaming the pasted entry is the normal case, not the
		-- exception — it is the only way to copy into the source's own folder.
		local id = vim.api.nvim_buf_set_extmark(buf, M.ns, at + i - 1, 0, { right_gravity = false })
		st.copy_targets[id] = { src = src.path, type = src.type }
	end
	flash(buf, at + 1, at + #clip)

	vim.api.nvim_win_set_cursor(0, { at + 1, 0 })
end

----------------------------------------------------------------------
-- Save-time resolution
----------------------------------------------------------------------

--- lnum → { src, type } for every live paste-target mark.
---@param buf number
---@return table
function M.pending(buf)
	local st = state.get(buf)
	local targets = st and st.copy_targets
	if not targets then
		return {}
	end
	local out = {}
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, M.ns, 0, -1, {})) do
		local target = targets[mark[1]]
		if target then
			out[mark[2] + 1] = target
		end
	end
	return out
end

--- Split parsed buffer entries into copy operations and the rest.
---
--- Entries below a copy destination are dropped too: the recursive copy
--- produces them, so passing them to the diff would ask for a second,
--- conflicting create of the same path.
---@param buf         number
---@param buf_entries table[]  from buffer.parse_buffer
---@return table[] copies  { { src = string, dst = entry } }
---@return table[] rest    entries the normal diff should see
---@return table[] errors  { lnum, message }
function M.split(buf, buf_entries)
	local pending = M.pending(buf)
	if not next(pending) then
		return {}, buf_entries, {}
	end

	local copies, rest, errors = {}, {}, {}
	local copied_dirs = {}

	for _, be in ipairs(buf_entries) do
		local target = not be.synthetic and pending[be.lnum] or nil
		if target then
			if not vim.loop.fs_stat(target.src) then
				errors[#errors + 1] = {
					lnum = be.lnum,
					message = string.format(
						"Line %d: the yanked source '%s' no longer exists — nothing was saved.",
						be.lnum,
						target.src
					),
				}
			elseif vim.loop.fs_stat(be.path) then
				errors[#errors + 1] = {
					lnum = be.lnum,
					message = string.format(
						"Line %d: '%s' already exists — rename the pasted entry; nothing was saved.",
						be.lnum,
						be.name
					),
				}
			end
			copies[#copies + 1] = { src = target.src, dst = be }
			if be.type == "dir" then
				copied_dirs[#copied_dirs + 1] = be.path
			end
		else
			rest[#rest + 1] = be
		end
	end

	if #copied_dirs > 0 then
		local kept = {}
		for _, be in ipairs(rest) do
			local nested = false
			for _, dir in ipairs(copied_dirs) do
				if under(be.path, dir) then
					nested = true
					break
				end
			end
			if not nested then
				kept[#kept + 1] = be
			end
		end
		rest = kept
	end

	return copies, rest, errors
end

return M
