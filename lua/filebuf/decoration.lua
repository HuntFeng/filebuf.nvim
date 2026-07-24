----------------------------------------------------------------------
-- Decoration provider.  Registered once in setup(); Neovim calls on_win on
-- every redraw, so git/dir/hidden/link extmarks are always current without
-- manual clear/refresh.  Work is O(visible viewport), never O(buffer).
----------------------------------------------------------------------
local config = require("filebuf.config")
local prof = require("filebuf.profiler")
local line_mod = require("filebuf.line")
local buffer = require("filebuf.buffer")
local git = require("filebuf.git")

local M = {}

--- Shared namespace for all filebuf decorations.
M.ns = vim.api.nvim_create_namespace("filebuf-deco")

--- on_start: skip the whole redraw cycle when no filebuf window is visible.
function M.on_start()
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		if vim.b[vim.api.nvim_win_get_buf(winid)].filebuf_root then
			return true
		end
	end
	return false
end

--- Resolve a lnum→entry map for a filebuf buffer.  Uses the cached display
--- entries when clean; re-parses (recovering is_hidden from the full cache)
--- when the buffer has been edited.
--- During rebuild (filebuf_rebuilding flag), display entries are set before
--- nvim_buf_set_lines so they are already current; returning them directly
--- avoids ~9 redundant parse_buffer calls per save.
local function entries_for(bufnr)
	prof.start("decoration.entries_for")
	-- Fast path during rebuild: entries are pre-stamped before the buffer
	-- content is replaced, so they already match what's on screen.
	if vim.b[bufnr].filebuf_rebuilding then
		prof.stop()
		return vim.b[bufnr].filebuf_display_entries
	end
	if not vim.bo[bufnr].modified then
		prof.stop()
		return vim.b[bufnr].filebuf_display_entries
	end
	local entries = {}
	for _, e in ipairs(buffer.parse_buffer(bufnr)) do
		entries[e.lnum] = e
	end
	-- is_hidden/is_ignored aren't in the buffer text; recover them from the full
	-- cache.
	local all = vim.b[bufnr].filebuf_all_entries
	if all then
		local by_path = {}
		for _, e in ipairs(all) do
			by_path[e.path] = e
		end
		for _, e in pairs(entries) do
			local cached = by_path[e.path]
			if cached then
				e.is_hidden = cached.is_hidden
				e.is_ignored = cached.is_ignored
				e.lazy = cached.lazy
			end
		end
	end
	prof.stop()
	return entries
end

--- on_win: apply ephemeral dir/link/hidden/git extmarks to the visible lines.
--- Fold-aware — closed-fold interiors are skipped.
--- Priorities: dir (10) > link (8) > hidden (5) > git (0).
function M.on_win(_, winid, bufnr, toprow, botrow)
	prof.start("decoration.on_win")
	if not vim.b[bufnr].filebuf_root then
		prof.stop()
		return false
	end
	-- During rebuild, entries are pre-stamped and buffer content is still
	-- being manipulated (fold operations, etc.).  Skip all extmark work — the
	-- final redraw after filebuf_rebuilding is cleared will decorate
	-- everything correctly in one pass.
	if vim.b[bufnr].filebuf_rebuilding then
		prof.stop()
		return false
	end
	local entries = entries_for(bufnr)
	if not entries then
		prof.stop()
		return false
	end

	local height = vim.api.nvim_win_get_height(winid)
	local use_tabs = not vim.go.expandtab
	local iw = line_mod.indent_width()
	local status_map = config.git_status and vim.b[bufnr].filebuf_git_status or nil

	local lnum = toprow + 1 -- toprow is 0-indexed; entries is 1-indexed
	local count = 0
	while lnum <= botrow + 1 and count <= height + 2 do
		local entry = entries[lnum]
		if entry then
			local name_start = use_tabs and entry.indent or (entry.indent * iw)
			local suffix = (entry.type == "dir" or entry.type == "link") and 1 or 0 -- "/" or "@"
			local name_end = name_start + #entry.name + suffix

			if entry.type == "dir" and not entry.is_hidden and not entry.is_ignored then
				vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum - 1, name_start, {
					end_col = name_end,
					hl_group = "Directory",
					priority = 10,
					ephemeral = true,
				})
			elseif entry.type == "link" then
				vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum - 1, name_start, {
					end_col = name_end,
					hl_group = "FilebufLink",
					priority = 8,
					ephemeral = true,
				})
			end

			if entry.is_hidden or entry.is_ignored then
				vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum - 1, name_start, {
					end_col = name_end,
					hl_group = entry.type == "dir" and "FilebufHiddenDir" or "FilebufHiddenFile",
					priority = 5,
					ephemeral = true,
				})
			end

			if status_map then
				local char, hl = git.entry_status(entry, status_map)
				if char then
					local opts = {
						virt_text = { { " " .. char, hl } },
						priority = 0,
						ephemeral = true,
						end_col = name_end,
					}
					if entry.type ~= "dir" then
						opts.hl_group = hl
					end
					vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum - 1, name_start, opts)
				end
			end
		end

		count = count + 1
		local fold_end = vim.fn.foldclosedend(lnum)
		lnum = fold_end ~= -1 and fold_end + 1 or lnum + 1
	end

	prof.stop()
	return false
end

return M
