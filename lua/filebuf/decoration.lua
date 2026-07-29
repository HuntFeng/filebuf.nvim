----------------------------------------------------------------------
-- Decoration provider.  Registered once in setup(); Neovim calls on_win
-- on every redraw, so git/dir/hidden/link extmarks are always current
-- without manual clear/refresh.
--
-- Work is O(visible viewport): each visible line resolves its path by
-- walking up the buffer (typically < 20 lines per lookup for indent).
----------------------------------------------------------------------
local config = require("filebuf.config")
local prof = require("filebuf.profiler")
local line_mod = require("filebuf.line")
local state = require("filebuf.state")
local git = require("filebuf.git")

local M = {}

--- Shared namespace for all filebuf decorations.
M.ns = vim.api.nvim_create_namespace("filebuf-deco")

--- on_start: skip the whole redraw cycle when no filebuf window is visible.
function M.on_start()
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		if state.is_filebuf(vim.api.nvim_win_get_buf(winid)) then
			return true
		end
	end
	return false
end

--- on_win: apply ephemeral dir/link/hidden/git extmarks to the visible lines.
--- Fold-aware — closed-fold interiors are skipped.
--- Priorities: search (20) > dir (10) > link (8) > hidden (5) > git (0).
function M.on_win(_, winid, bufnr, toprow, botrow)
	prof.start("decoration.on_win")
	local st = state.get(bufnr)
	if not st then
		prof.stop()
		return false
	end
	-- During a render, buffer content and folds are both mid-flight.
	if st.rendering then
		prof.stop()
		return false
	end

	local height = vim.api.nvim_win_get_height(winid)
	local use_tabs = not vim.go.expandtab
	local iw = line_mod.indent_width()
	local status_map = config.git_status and st.git or nil
	local matches = st.matches
	local ignore_set = st.ignore_set

	local lnum = toprow + 1 -- toprow is 0-indexed; lines are 1-indexed
	local count = 0
	while lnum <= botrow + 1 and count <= height + 2 do
		local entry = state.resolve_entry(bufnr, lnum)
		if entry then
			local name_start = use_tabs and entry.indent or (entry.indent * iw)
			local suffix = (entry.type == "dir" or entry.type == "link") and 1 or 0
			local name_end = name_start + #entry.name + suffix

			-- Check if ignored via gitignore set.
			local is_ignored = ignore_set and ignore_set[entry.path]

			if entry.type == "dir" and not entry.is_hidden and not is_ignored then
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

			if entry.is_hidden or is_ignored then
				vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum - 1, name_start, {
					end_col = name_end,
					hl_group = entry.type == "dir" and "FilebufHiddenDir" or "FilebufHiddenFile",
					priority = 5,
					ephemeral = true,
				})
			end

			-- Above Directory (10) so a revealed match stands out.
			if matches and matches[entry.path] then
				vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum - 1, name_start, {
					end_col = name_end,
					hl_group = "FilebufSearchMatch",
					priority = 20,
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
