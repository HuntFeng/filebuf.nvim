----------------------------------------------------------------------
-- .ignore / .gitignore parsing utilities.
--
-- Pattern matching (compile / matches) has been replaced by git
-- ls-files --others --ignored --exclude-standard for performance:
-- a single hash-set lookup per entry instead of per-entry Lua pattern
-- matching against accumulated rules.  parse_ignore_file is kept for
-- future use when non-git ignore files are needed.
----------------------------------------------------------------------
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

return M
