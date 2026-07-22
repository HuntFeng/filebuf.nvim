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
	FilebufLink = { fg = "#56b6c2" }, -- cyan, to distinguish from Directory (blue)
	FilebufLazyDir = { fg = "#5c6370", italic = true }, -- dimmed + italic for unloaded dirs
}

--- Create FilebufFoldLine = Directory's fg on Normal's bg, used by
--- winhighlight to override the Folded group.  A plain link to Directory
--- leaks Folded's background (Directory usually sets only fg), so we resolve
--- both attributes at setup time and set them explicitly.
local function define_fold_line()
	if not pcall(vim.api.nvim_get_hl, 0, { name = "Normal" }) then
		vim.api.nvim_set_hl(0, "FilebufFoldLine", { link = "Directory", default = true })
		return
	end
	local function attr(name, key)
		local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name })
		return ok and hl and hl[key] or nil
	end
	local dir_fg = attr("Directory", "fg")
	local normal_bg = attr("Normal", "bg")
	if dir_fg or normal_bg then
		vim.api.nvim_set_hl(0, "FilebufFoldLine", { fg = dir_fg, bg = normal_bg, default = true })
	else
		vim.api.nvim_set_hl(0, "FilebufFoldLine", { link = "Directory", default = true })
	end
end

--- Define every filebuf highlight group.  Called from setup().
function M.define()
	for name, def in pairs(GROUPS) do
		vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", def, { default = true }))
	end
	define_fold_line()
end

return M
