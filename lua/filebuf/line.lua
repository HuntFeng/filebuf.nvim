----------------------------------------------------------------------
-- Line formatting — convert entries to/from their buffer text form.
----------------------------------------------------------------------
local M = {}

--- Width of one indent level in spaces (when expandtab is set).
---@return number
function M.indent_width()
	local sw = vim.go.shiftwidth
	return (sw > 0 and sw) or vim.go.tabstop
end

--- Build the indent prefix for a given depth level.
---@param level number
---@return string
function M.indent_str(level)
	if level <= 0 then
		return ""
	end
	if not vim.go.expandtab then
		return string.rep("\t", level)
	end
	return string.rep(" ", level * M.indent_width())
end

--- Compute the indent depth level from a buffer line's leading whitespace.
---@param line string
---@return number
function M.indent_level(line)
	local ws = line:match("^(%s*)") or ""
	if not vim.go.expandtab then
		local _, count = ws:gsub("\t", "")
		return count
	end
	return math.floor(#ws / M.indent_width())
end

local ESCAPE = { ["\n"] = "$'\\n'", ["\r"] = "$'\\r'", ["\t"] = "$'\\t'" }

--- Build the display line for an entry.  Directories get a trailing "/",
--- symlinks a trailing "@".  Control characters are escaped in shell $'...'
--- notation so nvim_buf_set_lines accepts the line and parse_line can undo it.
---@param entry table  { name, type, indent? }
---@return string
function M.format_line(entry)
	local prefix = M.indent_str(entry.indent or 0)
	local suffix = entry.type == "dir" and "/" or (entry.type == "link" and "@" or "")
	local name = entry.name:gsub("[\n\r\t]", ESCAPE)
	return prefix .. name .. suffix
end

--- Parse a display line: strip leading whitespace, detect the trailing-slash
--- dir marker and trailing-@ symlink marker, and reverse format_line escaping.
---@param line string
---@return string name   cleaned name (no indent, no trailing / or @)
---@return boolean is_dir
---@return boolean is_link
function M.parse_line(line)
	local name = line:match("^%s*(.+)") or ""
	local is_dir = name:sub(-1) == "/"
	local is_link = name:sub(-1) == "@" and not is_dir
	if is_dir or is_link then
		name = name:sub(1, -2)
	end
	name = name:gsub("%$'\\n'", "\n"):gsub("%$'\\r'", "\r"):gsub("%$'\\t'", "\t")
	return name, is_dir, is_link
end

return M
