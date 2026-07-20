----------------------------------------------------------------------
-- Highlight groups.  All use default = true so a user's colorscheme wins.
----------------------------------------------------------------------
local M = {}

-- Git status colors + hidden/link entry colors.
local GROUPS = {
	FilebufGitAdded = { fg = "#98c379" },
	FilebufGitModified = { fg = "#e5c07b" },
	FilebufGitDeleted = { fg = "#e06c75" },
	FilebufGitUntracked = { fg = "#61afef" },
	FilebufGitConflict = { fg = "#c678dd" },
	FilebufGitRenamed = { fg = "#56b6c2" },
	FilebufHiddenFile = { fg = "#5c6370" },
	FilebufHiddenDir = { fg = "#5c6370" },
	FilebufLink = { fg = "#56b6c2" },
  FilebufFoldLine = { bg = nil} -- remove bg of foldlines
}

--- Define every filebuf highlight group.  Called from setup().
--- Folded-line coloring is now handled by FilebufFoldText (folds.lua) which
--- returns per-entry hl groups — no winhighlight / FilebufFoldLine needed.
function M.define()
	for name, def in pairs(GROUPS) do
		vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", def, { default = true }))
	end
end

return M
