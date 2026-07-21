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
		toggle_hidden = "H",
		close_filebuf = "q",
	},
}

return config
