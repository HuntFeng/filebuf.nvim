----------------------------------------------------------------------
-- Minimal Neovim configuration for running filebuf.nvim tests.
-- Used by: nvim --headless --noplugin -u tests/minimal_init.lua
----------------------------------------------------------------------

-- Locate plenary.nvim from several common paths (CI deps, lazy.nvim, etc.).
local plenary_paths = {
	".deps/plenary.nvim", -- CI: cloned into .deps/
	vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"), -- lazy.nvim (local dev)
	vim.fn.expand("~/.local/share/nvim/site/pack/plenary/start/plenary.nvim"), -- pack-based
}
for _, p in ipairs(plenary_paths) do
	if vim.fn.isdirectory(p) == 1 then
		vim.opt.runtimepath:prepend(p)
		break
	end
end

vim.opt.runtimepath:prepend(".")

-- Load plenary's vim plugin (registers :PlenaryBustedDirectory etc.).
vim.cmd("runtime! plugin/plenary.vim")

-- Consistent indent for tests.
vim.opt.expandtab = true
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2

-- Set up filebuf with test-friendly defaults.
require("filebuf").setup({
	permanent_delete = true, -- files are actually deleted (no trash)
	git_status = false, -- no git integration during tests
	hijack_netrw = false, -- don't intercept directory opens during tests
	respect_ignore = false, -- simplify scan behavior
	auto_focus_current_file = false, -- no auto-focus during tests
})
