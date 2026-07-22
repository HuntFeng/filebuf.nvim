--- Plugin configuration (mutated in place by setup()).
--- A single shared table so every module observes the same values.
---@class filebuf.Config
---@field permanent_delete boolean  when false, deleted entries are moved to a trash directory
---@field auto_focus_current_file boolean  when true, focus the tree on the file that was open before :Filebuf
---@field git_status boolean  when true, show git status indicators next to changed entries
---@field show_hidden boolean  when false, entries whose name starts with "." are hidden
---@field respect_ignore boolean  when true, .ignore/.gitignore patterns filter entries
---@field keymaps table  maps action names to key strings; set a value to false to disable
local config = {
	permanent_delete = true,
	auto_focus_current_file = true,
	git_status = true,
	show_hidden = false,
	respect_ignore = true,

	--- Directory names whose contents are never eagerly scanned.  These
	--- directories still appear as lazy placeholders (collapsed by default)
	--- and can be expanded on demand.  Each entry is a bare name, not a path.
	---@type string[]
	prune_dirs = {
		".git",
		"node_modules",
		"__pycache__",
		".venv",
		"venv",
		"build",
		"dist",
		".next",
		".nuxt",
		"target",
		"coverage",
		".pytest_cache",
		".mypy_cache",
		".ruff_cache",
	},

	--- When true (default), filebuf disables netrw and intercepts directory
	--- opens so `nvim <dir>` and `:e <dir>` open filebuf instead of netrw.
	--- Set to false if you need netrw for remote file editing (scp://, etc.).
	hijack_netrw = true,

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
		-- Entry actions
		open_or_toggle = "<CR>", -- toggle dir fold OR open file
		-- Buffer actions
		toggle_hidden = "gh",
		close_filebuf = "q",
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
	FilebufFoldLine = { bg = nil }, -- remove bg of foldlines
}

--- Define every filebuf highlight group.  Called from setup().
function config.define_highlights()
	for name, def in pairs(HIGHLIGHTS) do
		vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", def, { default = true }))
	end
end

--- Lazily-built set for O(1) prune-dir membership checks.
---@param name string  bare directory name
---@return boolean
function config.is_pruned_dir(name)
	if not config._prune_set or config._prune_version ~= #config.prune_dirs then
		config._prune_set = {}
		for _, d in ipairs(config.prune_dirs) do
			config._prune_set[d] = true
		end
		config._prune_version = #config.prune_dirs
	end
	return config._prune_set[name] == true
end

return config
