----------------------------------------------------------------------
-- Buffer parser — derives structured entries from the raw buffer text.
-- Runs only in the :w (BufWriteCmd) handler and during edits; read-only
-- navigation reuses the cached display entries.
----------------------------------------------------------------------
local prof = require("filebuf.profiler")
local line_mod = require("filebuf.line")

local M = {}

--- Parse the entire buffer in one pass, computing the full filesystem path
--- for every entry via an indent stack.
---@param buf   number
---@param root? string  filebuf root (defaults to the buffer's state root)
---@return table[]  { name, type, path, indent, lnum }
function M.parse_buffer(buf, root)
	prof.start("parse_buffer")
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	root = root or require("filebuf.state").root(buf)
	local entries = {}

	-- Indent settings are read once here rather than per line.  line.indent_level
	-- reads vim.go.expandtab and vim.go.shiftwidth on every call, which is an
	-- option lookup rather than a table read -- three of them per line, 450k on
	-- a 150k-line buffer, for values that cannot change mid-parse.  Same reason
	-- line.formatter exists on the rendering side.
	local use_tabs = not vim.go.expandtab
	local sw = vim.go.shiftwidth
	local width = (sw > 0 and sw) or vim.go.tabstop
	local indent_of
	if use_tabs then
		indent_of = function(line)
			local _, count = line:find("^\t*")
			return count
		end
	else
		indent_of = function(line)
			local _, count = line:find("^ *")
			return math.floor(count / width)
		end
	end

	-- Ancestry chain: a directory pushes { indent, path }; when indent
	-- decreases we pop until the top is a true ancestor (indent < current).
	local stack = {}

	--- Append one entry and, when it's a directory, push it as an ancestor.
	--- `synthetic` marks the intermediate directories invented for a
	--- "dir/subfile" line — they may legitimately repeat a directory that
	--- already has its own line, so validation has to skip them.
	local function add(name, is_dir, is_link, indent, lnum, synthetic)
		while #stack > 0 and stack[#stack].indent >= indent do
			table.remove(stack)
		end
		local parent = #stack > 0 and stack[#stack].path or root
		local path = parent .. "/" .. name
		if is_dir then
			stack[#stack + 1] = { indent = indent, path = path }
		end
		entries[#entries + 1] = {
			name = name,
			type = is_dir and "dir" or (is_link and "link" or "file"),
			path = path,
			indent = indent,
			lnum = lnum,
			synthetic = synthetic or nil,
		}
	end

	for lnum = 1, #lines do
		local line = lines[lnum]
		local name, is_dir, is_link = line_mod.parse_line(line)
		if line ~= "" and name ~= "" then
			local indent = indent_of(line)
			if not name:find("/", 1, true) then
				-- Fast path: most entries have no "/" in their name.
				add(name, is_dir, is_link, indent, lnum)
			else
				-- "dir/subfile" expands into synthetic dir entries plus the
				-- final child; intermediate segments are always directories.
				local parts = {}
				for part in name:gmatch("[^/]+") do
					parts[#parts + 1] = part
				end
				for i, part in ipairs(parts) do
					local part_is_dir = (i < #parts) or is_dir
					add(part, part_is_dir, is_link, indent + (i - 1), lnum, i < #parts)
				end
			end
		end
	end

	prof.stop()
	return entries
end

--- Execute fn with undo recording disabled for buf.  Restores the
--- original undolevels even if fn raises an error.
---@param buf number
---@param fn  fun()
function M.without_undo(buf, fn)
	local saved = vim.bo[buf].undolevels
	vim.bo[buf].undolevels = -1
	local ok, err = pcall(fn)
	vim.bo[buf].undolevels = saved
	if not ok then
		error(err)
	end
end

--- Clear all undo history for a buffer.
---@param buf number
function M.clear_undo(buf)
	pcall(vim.api.nvim_buf_clear_undo, buf)
end

return M
