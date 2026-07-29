----------------------------------------------------------------------
-- Tree search for lazily-loaded entries.
--
-- Every directory is lazy-loaded, so entries not yet on screen are invisible
-- to native `/`.  Use `g/` (find mode) for interactive asynchronous search,
-- or `:FilebufFind <pattern>` to query the whole tree synchronously with fd
-- (find(1) fallback) and load the ancestor chain of each hit — sibling
-- subdirectories along the way are listed but not expanded.  Matches are
-- highlighted via the decoration provider.
--
-- The pattern arrives as a Vim regex and has to be handed to a different
-- engine.  Vim-only atoms are stripped and, if any other escape survives, the
-- query degrades to a literal-substring search.  The find(1) fallback is
-- always a case-insensitive basename substring match — find has no regex.
----------------------------------------------------------------------
local config = require("filebuf.config")
local prof = require("filebuf.profiler")
local actions = require("filebuf.actions")
local state = require("filebuf.state")

local M = {}

--- Cached fd executable name ("fd" or "fdfind"); false when absent.
local _fd_cmd
local function fd_cmd()
	if _fd_cmd == nil then
		if vim.fn.executable("fd") == 1 then
			_fd_cmd = "fd"
		elseif vim.fn.executable("fdfind") == 1 then
			_fd_cmd = "fdfind"
		else
			_fd_cmd = false
		end
	end
	return _fd_cmd or nil
end

--- Vim-only regex atoms that have no equivalent in fd's engine.  Dropping them
--- keeps the surrounding pattern usable instead of erroring out.
local VIM_ATOMS = { "\\v", "\\V", "\\m", "\\M", "\\<", "\\>", "\\zs", "\\ze" }

--- Translate a Vim search pattern into a pattern for fd.
---@param pattern string
---@return string  translated pattern
---@return boolean literal      pass it to fd as a fixed string
---@return boolean ignore_case  the pattern requested case-insensitivity (\c)
local function translate_pattern(pattern)
	local ignore_case = false
	local p = pattern

	if p:find("\\c", 1, true) then
		ignore_case = true
	end
	p = p:gsub("\\[cC]", "")
	for _, atom in ipairs(VIM_ATOMS) do
		p = p:gsub(vim.pesc(atom), "")
	end

	-- Any remaining backslash escape is Vim-specific enough that reinterpreting
	-- it as a Rust regex would silently change the meaning.  Strip the
	-- backslashes and search for the literal text instead.
	if p:find("\\", 1, true) then
		return (p:gsub("\\", "")), true, ignore_case
	end
	return p, false, ignore_case
end

--- Cached fd executable name ("fd" or "fdfind"); false when absent.
--- Exported so find.lua can reuse it.
function M.fd_cmd()
	return fd_cmd()
end

--- Build an fd argv for searching under root for pattern.
--- Returns nil if the pattern translates to empty or if fd is unavailable.
---@param root    string
---@param pattern string  a Vim search pattern
---@param show_hidden? boolean  defaults to config.show_hidden
---@return string[]|nil  argv ready for vim.system or vim.fn.systemlist
function M.build_fd_argv(root, pattern, show_hidden)
	local fd = fd_cmd()
	if not fd then
		return nil
	end
	if show_hidden == nil then
		show_hidden = config.show_hidden
	end

	local limit = config.search_max_results
	local translated, literal, ignore_case = translate_pattern(pattern)
	if translated == "" then
		return nil
	end

	local argv = { fd, "--color", "never", "--max-results", tostring(limit + 1) }
	if show_hidden then
		argv[#argv + 1] = "-H"
	end
	if literal then
		argv[#argv + 1] = "--fixed-strings"
	end
	if ignore_case then
		argv[#argv + 1] = "--ignore-case"
	end
	vim.list_extend(argv, { "--", translated, root })
	return argv
end

--- Query the tree under `root` for `pattern` synchronously.
---
--- Mirrors config so results can actually be displayed: hidden entries are
--- only searched when show_hidden is on — revealing a hit that filter_visible
--- would drop is pointless.
---@param root    string
---@param pattern string  a Vim search pattern
---@param show_hidden? boolean  defaults to config.show_hidden
---@return string[] paths  absolute paths, at most config.search_max_results
---@return boolean  truncated  the cap was hit and results were dropped
function M.query(root, pattern, show_hidden)
	prof.start("search.query")
	if show_hidden == nil then
		show_hidden = config.show_hidden
	end
	local limit = config.search_max_results
	local translated, literal, ignore_case = translate_pattern(pattern)
	if translated == "" then
		prof.stop()
		return {}, false
	end

	local out
	local argv = M.build_fd_argv(root, pattern, show_hidden)
	if argv then
		out = vim.fn.systemlist(argv)
	else
		-- fd unavailable: use find fallback (no regex, case-insensitive basename match).
		-- Hidden/ignored filtering happens below.
		local needle = literal and translated or translated:gsub("[%*%?%[%]%(%)%|%+%^%$%.]", "")
		if needle == "" then
			prof.stop()
			return {}, false
		end
		out = vim.fn.systemlist({ "find", root, "-mindepth", "1", "-iname", "*" .. needle .. "*" })
	end

	local paths = {}
	local truncated = false
	for _, raw in ipairs(out) do
		-- fd appends "/" to directories; entry paths never carry one.
		local path = raw:sub(-1) == "/" and raw:sub(1, -2) or raw
		if path ~= "" and vim.startswith(path, root .. "/") then
			local rel = path:sub(#root + 2)
			-- Skip hits under a dot-prefixed component when hidden entries
			-- aren't shown; reveal_path could not surface them anyway.  fd
			-- already excludes these, but find does not.
			local skip = false
			if not show_hidden then
				for component in rel:gmatch("[^/]+") do
					if component:sub(1, 1) == "." then
						skip = true
						break
					end
				end
			end
			if not skip then
				if #paths >= limit then
					truncated = true
					break
				end
				paths[#paths + 1] = path
			end
		end
	end

	prof.stop()
	return paths, truncated
end

--- The path of the entry under the cursor, or nil.
local function cursor_path(buf)
	local entry = state.entry_at_cursor(buf)
	return entry and entry.path or nil
end

--- Search, reveal every hit's ancestor chain, highlight the matches and place
--- the cursor on one of them.
---
--- Always queries the tree, even when the pattern already matches on screen:
--- finding an entry in the buffer says nothing about how many more are still
--- unloaded on disk.
---
--- @/ is left alone — the caller (e.g. :FilebufFind) owns it, and the user's
--- pattern still matches the freshly-revealed basename lines, so n/N keep
--- working.
---@param buf     number
---@param pattern string  a Vim search pattern
---@return number  how many matches were revealed
function M.run(buf, pattern)
	prof.start("search.run")
	local root = state.root(buf)
	if not root then
		prof.stop()
		return 0
	end

	-- Whether the pattern matches something already on screen.  Only used to
	-- decide whether silence is appropriate: a Vim regex that matches buffer
	-- text but no basename (say "^ *b") legitimately yields no disk hits, and
	-- complaining about it would be wrong.
	local matched_locally = vim.fn.search(pattern, "nw") ~= 0
	local was_on = cursor_path(buf)

	M.clear(buf)

	local st = state.get(buf)
	local paths, truncated = M.query(root, pattern, st and st.show_hidden)
	if #paths == 0 then
		if not matched_locally then
			vim.notify("filebuf: pattern not found: " .. pattern, vim.log.levels.WARN)
		end
		prof.stop()
		return 0
	end

	local entries = actions.reveal_paths(buf, paths)
	if #entries == 0 then
		vim.notify(
			string.format("filebuf: %d match(es) for '%s', none reachable in the current view", #paths, pattern),
			vim.log.levels.WARN
		)
		prof.stop()
		return 0
	end

	local matches = {}
	for _, e in ipairs(entries) do
		matches[e.path] = true
	end
	local st = state.get(buf)
	if st then
		st.matches = matches
	end

	-- Cursor: if it already sits on a match (the native search having just
	-- jumped there), keep it — revealing shifted the line, not the entry.
	-- Otherwise go to the topmost match.
	table.sort(entries, function(a, b)
		return a.lnum < b.lnum
	end)
	local target = entries[1]
	if was_on and matches[was_on] then
		for _, e in ipairs(entries) do
			if e.path == was_on then
				target = e
				break
			end
		end
	end
	vim.api.nvim_win_set_cursor(0, { target.lnum, 0 })
	vim.cmd("normal! zz")

	local msg = string.format("filebuf: %d match(es) for '%s'", #entries, pattern)
	if truncated then
		msg = msg .. string.format(" (capped at %d; refine the pattern)", config.search_max_results)
	end
	if #entries < #paths then
		msg = msg .. string.format(" — %d hidden/unreachable hit(s) skipped", #paths - #entries)
	end
	vim.notify(msg, vim.log.levels.INFO)

	prof.stop()
	return #entries
end

--- Drop the highlighted match set for `buf`.
---@param buf number
function M.clear(buf)
	local st = state.get(buf)
	if st then
		st.matches = nil
	end
end

return M
