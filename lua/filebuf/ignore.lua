----------------------------------------------------------------------
-- .ignore / .gitignore support for the find(1) fallback scanner.
-- (The fd fast path delegates ignore handling to fd itself.)
----------------------------------------------------------------------
local prof = require("filebuf.profiler")

local M = {}

--- Parse a .ignore file into a list of { raw, negate } patterns.
--- Supports # comments, blank lines, trailing "/" for dir-only patterns,
--- and leading "!" negation (which re-includes; last matching pattern wins).
---@param path string  full filesystem path to the .ignore file
---@return table[]  { raw = string, negate = boolean }
function M.parse_ignore_file(path)
	local lines = vim.fn.readfile(path)
	if type(lines) ~= "table" then
		return {}
	end
	local patterns = {}
	for _, line in ipairs(lines) do
		line = line:match("^%s*(.-)%s*$")
		if line ~= "" and line:sub(1, 1) ~= "#" then
			local negate = false
			if line:sub(1, 1) == "!" then
				negate = true
				line = line:sub(2)
			elseif line:sub(1, 2) == "\\!" then
				line = line:sub(2) -- strip the backslash, keep literal "!"
			end
			patterns[#patterns + 1] = { raw = line, negate = negate }
		end
	end
	return patterns
end

--- Check if an entry matches any ignore pattern.  Supports "*" wildcards,
--- trailing "/" (dir-only), path-based patterns (containing "/"), and
--- negation (leading "!"); the last matching pattern wins.  Compiled Lua
--- patterns are cached on the pattern object so the glob→Lua conversion
--- happens once per pattern, not once per entry.
---@param full_path    string
---@param name         string
---@param patterns     table[]  { raw, negate?, source_dir }
---@param is_dir       boolean
---@param negate_count number   count of negate=true patterns (enables early exit)
---@return boolean
function M.matches_ignore(full_path, name, patterns, is_dir, negate_count)
	prof.start("matches_ignore")
	if not patterns or #patterns == 0 then
		prof.stop()
		return false
	end
	-- With no active negation patterns, the first match is definitive.
	local can_early_exit = (negate_count or 0) == 0
	local matched = false
	for _, pat in ipairs(patterns) do
		if not pat._lua_pattern then
			local p = pat.raw
			local dir_only = p:sub(-1) == "/"
			if dir_only then
				p = p:sub(1, -2)
			end
			-- Escape all Lua magic characters except *, then turn * into .*
			local escaped = p:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1")
			escaped = escaped:gsub("%*", ".*")
			pat._lua_pattern = "^" .. escaped .. "$"
			pat._dir_only = dir_only
			pat._has_slash = pat.raw:find("/") ~= nil
		end

		if not (pat._dir_only and not is_dir) then
			local target = pat._has_slash and full_path:sub(#pat.source_dir + 2) or name
			if target and target:match(pat._lua_pattern) then
				if can_early_exit then
					prof.stop()
					return true
				end
				matched = not pat.negate -- negation patterns un-ignore
			end
		end
	end
	prof.stop()
	return matched
end

return M
