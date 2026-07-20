----------------------------------------------------------------------
-- Manual folds — each directory folds together with all its descendants.
----------------------------------------------------------------------
local prof = require("filebuf.profiler")
local buffer = require("filebuf.buffer")

local M = {}

--- Persisted fold-closed state, keyed by root directory.  Each value is a
--- set of paths whose folds were closed; survives buffer close/reopen so
--- the user's fold preferences stick.
M.closed = {}

--- Create a fold spanning each directory and its descendants (nested dirs get
--- their own inner folds).  Single O(n) stack pass: directories are pushed
--- when seen and their fold emitted when an entry at ≤ indent arrives.  The
--- LIFO order emits inner folds before outer ones, as Neovim requires.
---@param buf number
---@param entries? table[]  pre-parsed entries (avoids a redundant parse)
function M.create_folds(buf, entries)
	prof.start("create_folds")
	entries = entries or buffer.parse_buffer(buf)
	if #entries == 0 then
		prof.stop()
		return
	end

	local stack = {} -- { lnum, indent }
	local prev -- last entry seen (fold endpoint)
	local cmds = {}

	local function close_dir(d)
		if prev and prev.indent > d.indent and prev.lnum > d.lnum then
			cmds[#cmds + 1] = string.format("%d,%dfold", d.lnum, prev.lnum)
		end
	end

	for _, e in ipairs(entries) do
		-- Pop directories whose subtree has ended (current indent back at or
		-- above theirs); prev is that subtree's last line.
		while #stack > 0 and stack[#stack].indent >= e.indent do
			close_dir(table.remove(stack))
		end
		if e.type == "dir" then
			stack[#stack + 1] = { lnum = e.lnum, indent = e.indent }
		end
		prev = e
	end
	while #stack > 0 do
		close_dir(table.remove(stack))
	end

	if #cmds > 0 then
		vim.cmd(table.concat(cmds, "|"))
	end
	prof.stop()
end

--- Persist the closed-fold set for `root` from the current buffer.
---@param buf number
---@param root string
---@param entries? table[]  pre-parsed display entries (each carrying lnum)
function M.save_fold_state(buf, root, entries)
	M.closed[root] = {}
	entries = entries or vim.b[buf].filebuf_display_entries or {}
	for _, e in ipairs(entries) do
		if e.type == "dir" and vim.fn.foldclosed(e.lnum) ~= -1 then
			M.closed[root][e.path] = true
		end
	end
end

--- Fold-text callback (v:lua.FilebufFoldText).  Shows the entry name with
--- its indent converted to spaces so it aligns regardless of tabstop.
function _G.FilebufFoldText()
	local line = vim.fn.getline(vim.v.foldstart)
	local indent_ws = line:match("^(%s*)") or ""
	local name = line:match("^%s*(.-)%s*$") or line
	local buf = vim.api.nvim_get_current_buf()
	local entries = vim.b[buf].filebuf_display_entries
	local entry = entries[vim.v.foldstart]
	local text = string.rep(" ", vim.fn.strdisplaywidth(indent_ws)) .. name
	local hl = "Directory"
	if entry.is_hidden or entry.is_ignored then
		hl = "FilebufHiddenDir"
	end
	return { { text, hl } }
end

return M
