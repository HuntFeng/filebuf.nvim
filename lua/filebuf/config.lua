--- Plugin configuration (mutated in place by setup()).
--- A single shared table so every module observes the same values.
---@class filebuf.Config
---@field permanent_delete boolean  when false, deleted entries are moved to a trash directory
---@field auto_focus_current_file boolean  when true, focus the tree on the file that was open before :Filebuf
---@field git_status boolean  when true, show git status indicators next to changed entries
---@field show_hidden boolean  when false, entries whose name starts with "." are hidden
---@field sort_method string  sort order: "type" | "name" | "modified" | "created"
---@field save_confirmation boolean  when true, show a confirmation dialog before :w applies changes to the filesystem
---@field keymaps table  maps action names to key strings; set a value to false to disable
local config = {
	permanent_delete = false,
	auto_focus_current_file = true,
	git_status = true,
	show_hidden = false,
	save_confirmation = true,
	max_depth = 20,
	hijack_netrw = true,
	sort_method = "type",
	---@type table<string, string|boolean>
	keymaps = {
		open_file = "gf",
		open_or_toggle = "<CR>",
		preview = "K",
		toggle_hidden = "gh",
		close_filebuf = "q",
		copy = "gy",
		paste = "gp",
		find_mode = "g/",
		find_mode_full = "",
		sort_by_name = "",
		sort_by_type = "",
		sort_by_ctime = "",
		sort_by_mtime = "",
	},
}

--- Git status colors + hidden/link entry colors.
---@type table<string, table>
local HIGHLIGHTS = {
	FilebufGitAdded = { fg = "#98c379" },
	FilebufGitModified = { fg = "#e5c07b" },
	FilebufGitDeleted = { fg = "#e06c75" },
	FilebufGitUntracked = { fg = "#61afef" },
	FilebufGitConflict = { fg = "#c678dd" },
	FilebufGitRenamed = { fg = "#56b6c2" },
	FilebufHiddenFile = { fg = "#5c6370" },
	FilebufHiddenDir = { fg = "#5c6370" },
	FilebufLink = { fg = "#56b6c2" },
	-- Entries revealed by tree search (find mode / :FilebufFind).  Linked rather
	-- colour so it follows the colourscheme's search highlight.
	FilebufSearchMatch = { link = "Search" },
	-- Flash shown on yanked/pasted lines, mirroring the native TextYankPost flash.
	FilebufCopyMark = { link = "Visual" },
	FilebufFoldLine = { bg = nil }, -- remove bg of foldlines
}

--- Define every filebuf highlight group.  Called from setup().
function config.define_highlights()
	for name, def in pairs(HIGHLIGHTS) do
		vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", def, { default = true }))
	end
	-- WinBar is a built-in Neovim highlight group.
	-- Don't use default=true
	vim.api.nvim_set_hl(0, "WinBar", { link = "TabLineSel" })
end

return config
