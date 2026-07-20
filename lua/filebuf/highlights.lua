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
}

--- Create FilebufFoldLine = Normal's fg on Normal's bg, used by winhighlight
--- to override the Folded group.  We intentionally do NOT use Directory's fg
--- here — extmarks on directory names (Directory / FilebufHiddenDir) provide
--- the correct per-entry coloring even on folded lines, and a neutral fold
--- line ensures the extmark color isn't overridden.
local function define_fold_line()
	-- if not pcall(vim.api.nvim_get_hl, 0, { name = "Normal" }) then
	-- 	vim.api.nvim_set_hl(0, "FilebufFoldLine", { link = "Normal", default = true })
	-- 	return
	-- end
	-- local function attr(name, key)
	-- 	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name })
	-- 	return ok and hl and hl[key] or nil
	-- end
	-- -- local normal_fg = attr("Directory", "fg")
	-- local normal_fg = attr("Directory", "fg")
	-- local normal_bg = attr("Directory", "bg")
	-- if normal_fg or normal_bg then
	-- 	vim.api.nvim_set_hl(0, "FilebufFoldLine", { fg = normal_fg, bg = normal_bg, default = true })
	-- else
	-- 	vim.api.nvim_set_hl(0, "FilebufFoldLine", { link = "Directory", default = true })
	-- end
end

--- Define every filebuf highlight group.  Called from setup().
function M.define()
	for name, def in pairs(GROUPS) do
		vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", def, { default = true }))
	end
	define_fold_line()
end

return M
