--- Plugin configuration (mutated in place by setup()).
--- A single shared table so every module observes the same values.
---@class filebuf.Config
---@field permanent_delete boolean  when false, deleted entries are moved to a trash directory
---@field auto_focus_current_file boolean  when true, focus the tree on the file that was open before :Filebuf
---@field git_status boolean  when true, show git status indicators next to changed entries
---@field show_hidden boolean  when false, entries whose name starts with "." are hidden
---@field respect_ignore boolean  when true, .ignore/.gitignore patterns filter entries
---@field sort_method string  sort order: "type" | "name" | "modified" | "created"
---@field save_confirmation boolean  when true, show a confirmation dialog before :w applies changes to the filesystem
---@field eager_load boolean  when true, scan the whole tree on open so native `/` sees every entry
---@field eager_max_entries number  cap on the eager scan; past it, folders load on demand
---@field search_max_results number  cap on hits returned by tree search (find mode / :FilebufFind)
---@field max_expand_entries number  cap on entries loaded by one recursive expand (zO)
---@field expand_confirm_threshold number|false  confirm before a recursive expand this large
---@field keymaps table  maps action names to key strings; set a value to false to disable
local config = {
	permanent_delete = false,
	auto_focus_current_file = true,
	git_status = true,
	show_hidden = false,
	respect_ignore = true,
	save_confirmation = true,

	--- Load the whole tree when opening a filebuf, so every entry is a real
	--- buffer line and Vim's own `/` searches all of it.  Directories still fold
	--- closed, so the initial view is unchanged.
	---
	--- Set to false to load one directory at a time instead; entries not yet on
	--- screen are then invisible to `/`, and `g/` (find mode) or `:FilebufFind`
	--- is the way to search the rest.
	eager_load = true,
	--- Upper bound on the eager scan.  Past this many entries the scan stops
	--- descending and the remaining folders load on demand, so opening a filebuf
	--- on `/` or a home directory cannot hang the editor.
	eager_max_entries = 200000,

	--- Cap on how many hits tree search (find mode / :FilebufFind) reveals.
	search_max_results = 500,
	--- Upper bound on how many entries a single recursive expand (zO) may
	--- load, so `zO` near the root of a huge tree cannot hang the editor.
	max_expand_entries = 20000,
	--- Ask for confirmation before a recursive expand (zO) that would load at
	--- least this many entries.  Set to false (or 0) to never ask.
	expand_confirm_threshold = 1000,

	--- When true (default), filebuf disables netrw and intercepts directory
	--- opens so `nvim <dir>` and `:e <dir>` open filebuf instead of netrw.
	--- Set to false if you need netrw for remote file editing (scp://, etc.).
	hijack_netrw = true,
	--- Default sort order for entries within each directory.
	--- You could change by FilebufSortMethod <method> on the fly
	sort_method = "type",

	--- Customizable keymaps.  Set any value to a key string to override,
	--- or to `false` to disable the binding entirely.
	---@type table<string, string|boolean>
	keymaps = {
		-- Directory fold actions
		fold_open = "zo",
		fold_close = "zc",
		fold_toggle = "za",
		fold_open_recursive = "zO",
		fold_open_all = "zR",
		fold_close_all = "zM",
		open_file = "gf",
		open_or_toggle = "<CR>",
		preview = "K",
		toggle_hidden = "gh",
		close_filebuf = "q",
		find_mode = "g/",
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
	FilebufFoldLine = { bg = nil }, -- remove bg of foldlines
	-- Mode banner (normal/find mode indicator).
	WinBar = { link = "TabLineSel" },
}

--- Define every filebuf highlight group.  Called from setup().
function config.define_highlights()
	for name, def in pairs(HIGHLIGHTS) do
		vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", def, { default = true }))
	end
	-- WinBar is a built-in Neovim highlight group.  Setting it with
	-- default=true would be a no-op (the built-in definition already
	-- exists), so we must set it without default=true for the link to
	-- actually take effect.
	vim.api.nvim_set_hl(0, "WinBar", { link = "TabLineSel" })
end

return config
