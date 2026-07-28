----------------------------------------------------------------------
-- .ignore / .gitignore parsing and matching.
--
-- The scanner reads the ignore files in scope for each directory it loads
-- (see scan.ignore_patterns_for) and tags matching entries is_ignored; they
-- are still listed, just dimmed or filtered by show_hidden.
--
-- Matching runs once per entry, so on a 100k-entry tree it runs 100k times
-- against every pattern in scope.  Running a Lua pattern for each was the
-- single largest cost in a full scan (~1.3s on a repo with a real .gitignore).
-- Patterns are therefore classified once, at compile time, into the three
-- shapes that actually occur:
--
--   exact    "node_modules", "Thumbs.db"   -> string equality
--   suffix   "*.log", "*.pyc"              -> compare the name's tail
--   complex  "src/**/gen-*", "!keep.ts"    -> a real Lua pattern
--
-- Real .gitignore files are overwhelmingly the first two, and when no negation
-- is present those collapse into hash lookups (see M.compile).
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

----------------------------------------------------------------------
-- Compilation
----------------------------------------------------------------------

--- Classify one pattern, filling in the fields the matcher dispatches on.
local function classify(pat)
	local raw = pat.raw
	local dir_only = raw:sub(-1) == "/"
	local body = dir_only and raw:sub(1, -2) or raw

	pat.dir_only = dir_only
	pat.has_slash = raw:find("/", 1, true) ~= nil and not (dir_only and not body:find("/", 1, true))

	if not pat.has_slash then
		if not body:find("[*?%[%]]") then
			pat.kind = "exact"
			pat.lit = body
			return pat
		end
		-- "*.ext" with no other wildcard: the common suffix rule.
		local ext = body:match("^%*([^*?%[%]/]+)$")
		if ext then
			pat.kind = "suffix"
			pat.ext = ext
			pat.ext_len = #ext
			return pat
		end
	end

	-- Escape all Lua magic characters except *, then turn * into .*
	local escaped = body:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1")
	escaped = escaped:gsub("%*", ".*")
	pat.kind = "complex"
	pat.lua_pattern = "^" .. escaped .. "$"
	return pat
end

--- Compile a pattern list into a matcher description.
---
--- With no negation in scope the result of a match doesn't depend on pattern
--- order, so exact and suffix rules collapse into hash lookups and only the
--- complex ones are iterated.  With a negation present, order decides the
--- outcome ("last match wins"), so evaluation stays sequential — but each step
--- is still an equality or tail comparison rather than a pattern match.
---@param patterns table[]  { raw, negate, source_dir }
---@return table compiled
function M.compile(patterns)
	local compiled = {
		ordered = patterns,
		has_negate = false,
		exact_any = {}, -- name -> true
		exact_dir = {}, -- name -> true, directories only
		ext_any = {}, -- ".log" -> true, hashed off the name's extension
		ext_dir = {},
		tails = {}, -- suffixes that aren't a dot extension ("~", "_test")
		complex = {},
	}

	for _, pat in ipairs(patterns) do
		classify(pat)
		if pat.negate then
			compiled.has_negate = true
		end
	end

	if compiled.has_negate then
		return compiled
	end

	for _, pat in ipairs(patterns) do
		if pat.kind == "exact" then
			if pat.dir_only then
				compiled.exact_dir[pat.lit] = true
			else
				compiled.exact_any[pat.lit] = true
			end
		elseif pat.kind == "suffix" then
			-- A dot extension can be hashed straight off the name; anything else
			-- has to be compared tail-first, so it goes in the (short) list.
			if pat.ext:match("^%.[^.]+$") then
				if pat.dir_only then
					compiled.ext_dir[pat.ext] = true
				else
					compiled.ext_any[pat.ext] = true
				end
			else
				compiled.tails[#compiled.tails + 1] = pat
			end
		else
			compiled.complex[#compiled.complex + 1] = pat
		end
	end

	return compiled
end

----------------------------------------------------------------------
-- Matching
----------------------------------------------------------------------

--- The text a pattern is tested against: the path relative to the ignore file's
--- directory for patterns containing "/", the bare name otherwise.
local function target_for(pat, full_path, name)
	if pat.has_slash then
		return full_path:sub(#pat.source_dir + 2)
	end
	return name
end

--- Does one compiled pattern match?
local function pattern_matches(pat, full_path, name, is_dir)
	if pat.dir_only and not is_dir then
		return false
	end
	local kind = pat.kind
	if kind == "exact" then
		return target_for(pat, full_path, name) == pat.lit
	elseif kind == "suffix" then
		local target = target_for(pat, full_path, name)
		return #target > pat.ext_len and target:sub(-pat.ext_len) == pat.ext
	end
	local target = target_for(pat, full_path, name)
	return target ~= nil and target:match(pat.lua_pattern) ~= nil
end

--- Test an entry against a compiled pattern set.
---@param compiled  table    from M.compile
---@param full_path string
---@param name      string
---@param is_dir    boolean
---@return boolean
function M.matches(compiled, full_path, name, is_dir)
	if not compiled then
		return false
	end

	if not compiled.has_negate then
		-- Order-independent, so the cheap tests can come first and most entries
		-- never reach a pattern match at all.
		if compiled.exact_any[name] or (is_dir and compiled.exact_dir[name]) then
			return true
		end

		local dot = name:match("^.*(%.[^.]*)$")
		if dot and (compiled.ext_any[dot] or (is_dir and compiled.ext_dir[dot])) then
			return true
		end

		for _, pat in ipairs(compiled.tails) do
			if pattern_matches(pat, full_path, name, is_dir) then
				return true
			end
		end
		for _, pat in ipairs(compiled.complex) do
			if pattern_matches(pat, full_path, name, is_dir) then
				return true
			end
		end
		return false
	end

	-- Negation in scope: last matching pattern decides.
	local matched = false
	for _, pat in ipairs(compiled.ordered) do
		if pattern_matches(pat, full_path, name, is_dir) then
			matched = not pat.negate
		end
	end
	return matched
end

return M
