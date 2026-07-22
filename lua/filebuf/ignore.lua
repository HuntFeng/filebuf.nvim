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

--- Convert .gitignore/.ignore patterns into find(1) -path expression
--- fragments, ordered cheapest→most-expensive for find's short-circuit
--- (-o) evaluation.
---
--- In GNU find, -path's `*` wildcard crosses "/" (fnmatch without
--- FNM_PATHNAME), so a single expression can match at any depth.
---
--- Patterns are classified into four groups in evaluation order:
---   1. Exact dir prunes   — literal name, dir-only  (fastest)
---   2. Exact excludes     — literal name, file/dir  (fast)
---   3. Wildcard dir prunes   — glob, dir-only       (slower)
---   4. Wildcard excludes     — glob, file/dir       (slowest)
---
--- Skipped: negated patterns, patterns with `**`, and unconvertible
--- character classes.  These remain handled by per-entry Lua matching.
---
---@param root_dir string
---@return table[]  { tokens = string[], dir_only = boolean }[]
function M.extract_find_expressions(root_dir)
	local groups = { {}, {}, {}, {} } -- G1..G4
	local seen = {}

	for _, fname in ipairs({ ".gitignore", ".ignore" }) do
		local fpath = root_dir .. "/" .. fname
		local fstat = vim.loop.fs_stat(fpath) if not fstat or fstat.type ~= "file" then
			goto continue_file
		end
		local patterns = M.parse_ignore_file(fpath)
		for _, pat in ipairs(patterns) do
			if pat.negate then
				goto continue_pat
			end

			local raw = pat.raw
			-- Skip patterns with ** (no clean find equivalent).
			if raw:find("%*%*", 1, true) then
				goto continue_pat
			end

			-- Trailing "/" = directory-only in gitignore.
			local dir_only = raw:sub(-1) == "/"
			if dir_only then
				raw = raw:sub(1, -2)
			end

			-- Leading "/" = root-anchored in gitignore.
			local anchored = raw:sub(1, 1) == "/"
			if anchored then
				raw = raw:sub(2)
			end

			-- Build the -path pattern.
			-- Patterns with a "/" in the body or an anchored leading "/"
			-- already have path context.  Bare names need a `*/` prefix
			-- so they match at any depth (find's `*` crosses "/").
			local path_pat
			local has_body_slash = raw:find("/", 1, true) ~= nil
			if anchored then
				path_pat = "./" .. raw
			elseif has_body_slash then
				path_pat = "*/" .. raw
			else
				-- Bare name — prepend "*/" so it matches at any depth.
				path_pat = "*/" .. raw
			end

			-- Detect glob characters for classification.
			local has_globs = raw:find("[%*%?%[]") ~= nil

			-- Deduplicate.
			if seen[path_pat] then
				goto continue_pat
			end
			seen[path_pat] = true

			-- Build find expression tokens.
			local tokens
			if dir_only then
				tokens = { "(", "-path", path_pat, "-printf", "%y\t%h\t%f\n", "-prune", ")" }
			else
				tokens = { "(", "-path", path_pat, ")" }
			end

			-- Classify into group.
			local gi
			if dir_only and not has_globs then
				gi = 1
			elseif not dir_only and not has_globs then
				gi = 2
			elseif dir_only and has_globs then
				gi = 3
			else
				gi = 4
			end

			groups[gi][#groups[gi] + 1] = { tokens = tokens }
			::continue_pat::
		end
		::continue_file::
	end
	return groups
end

return M
