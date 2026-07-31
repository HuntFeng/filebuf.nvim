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

--- Cached indent strings, invalidated when tab/space settings change.
local indent_cache = {}
local indent_cache_tabs = nil
local indent_cache_sw = nil

--- Build the indent prefix for a given depth level.
---@param level number
---@return string
function M.indent_str(level)
	if level <= 0 then
		return ""
	end
	local use_tabs = not vim.go.expandtab
	local sw = use_tabs and 0 or M.indent_width()
	-- Invalidate cache when indent settings change.
	if use_tabs ~= indent_cache_tabs or sw ~= indent_cache_sw then
		indent_cache = {}
		indent_cache_tabs = use_tabs
		indent_cache_sw = sw
	end
	local cached = indent_cache[level]
	if cached then
		return cached
	end
	local result
	if use_tabs then
		result = string.rep("\t", level)
	else
		result = string.rep(" ", level * sw)
	end
	indent_cache[level] = result
	return result
end

--- Compute the indent depth level from a buffer line's leading whitespace.
---@param line string
---@return number
function M.indent_level(line)
	local ws = line:match("^(%s*)") or ""
	local result
	if not vim.go.expandtab then
		local _, count = ws:gsub("\t", "")
		result = count
	else
		result = math.floor(#ws / M.indent_width())
	end
	return result
end

local ESCAPE = { ["\n"] = "$'\\n'", ["\r"] = "$'\\r'", ["\t"] = "$'\\t'" }

--- Build a formatter for one bulk render.
---
--- format_line re-reads vim.go.expandtab / shiftwidth on every call, which are
--- option lookups rather than table reads and dominate the cost when called
--- 100k times.  This captures them once and precomputes the indent prefixes,
--- making the per-entry path pure string concatenation (~4x faster).
---@return fun(entry: table): string
function M.formatter()
	local use_tabs = not vim.go.expandtab
	local sw = use_tabs and 1 or M.indent_width()
	local unit = use_tabs and "\t" or string.rep(" ", sw)
	local prefixes = { [0] = "" }

	local function prefix_for(level)
		local cached = prefixes[level]
		if cached then
			return cached
		end
		local built = string.rep(unit, level)
		prefixes[level] = built
		return built
	end

	return function(entry)
		local name = entry.name
		if name:find("[\n\r\t]") then
			name = name:gsub("[\n\r\t]", ESCAPE)
		end
		local type_ = entry.type
		local prefix = prefix_for(entry.indent or 0)
		if type_ == "dir" then
			return prefix .. name .. "/"
		elseif type_ == "link" then
			return prefix .. name .. "@"
		end
		return prefix .. name
	end
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
	-- Only run gsub if the escape sentinel is present (99%+ of names skip this).
	if name:find("$'", 1, true) then
		name = name:gsub("%$'\\n'", "\n"):gsub("%$'\\r'", "\r"):gsub("%$'\\t'", "\t")
	end
	return name, is_dir, is_link
end

return M
