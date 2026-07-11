local M = {}

--- Parse a .ignore file and return a list of patterns, each with
--- a `negate` flag.  Supports # comments, blank lines, and trailing /
--- for dir-only patterns.  Negation patterns (starting with `!`)
--- re-include files that would otherwise be ignored by an earlier
--- pattern; in gitignore semantics the last matching pattern wins.
---@param path string  full filesystem path to the .ignore file
---@return table[]  list of { raw = string, negate = boolean }
function M.parse_ignore_file(path)
  local lines = vim.fn.readfile(path)
  if type(lines) ~= "table" then return {} end
  local patterns = {}
  for _, line in ipairs(lines) do
    -- Strip leading/trailing whitespace
    line = line:match("^%s*(.-)%s*$")
    -- Skip blank lines and comments
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local negate = false
      -- A leading "!" means negate (re-include) the pattern.
      -- "\!" at the start is an escaped literal "!".
      if line:sub(1, 1) == "!" then
        negate = true
        line = line:sub(2)
      elseif line:sub(1, 2) == "\\!" then
        line = line:sub(2) -- strip the backslash, keep literal "!"
      end
      table.insert(patterns, { raw = line, negate = negate })
    end
  end
  return patterns
end

--- Check if an entry matches any ignore pattern.
--- Supports: * wildcard (any sequence of chars), trailing / (dir-only),
--- path-based patterns (containing "/"), and negation patterns (starting
--- with !).  The last matching pattern wins — a negation that appears
--- later in the ignore file overrides an earlier positive match.
---@param full_path string    full filesystem path of the entry
---@param name      string    entry basename
---@param patterns  table[]   { raw = string, negate? = boolean, source_dir = string }
---@param is_dir    boolean   whether the entry is a directory
---@return boolean
function M.matches_ignore(full_path, name, patterns, is_dir)
  if not patterns or #patterns == 0 then return false end
  local matched = false
  for _, pat in ipairs(patterns) do
    local dir_only = false
    local p = pat.raw
    -- Trailing "/" means match only directories
    if p:sub(-1) == "/" then
      dir_only = true
      p = p:sub(1, -2)
    end
    if dir_only and not is_dir then
      -- skip — trailing-slash patterns only match directories
    else
      -- Convert glob to Lua pattern:
      -- Escape all Lua magic characters except *, then replace * with .*
      local escaped = p:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1")
      escaped = escaped:gsub("%*", ".*")
      -- Anchor to match the full name
      local lua_pattern = "^" .. escaped .. "$"
      -- For path-based patterns (containing "/"), match against the
      -- entry's path relative to the .gitignore's directory.
      -- Otherwise match against the basename.
      local target
      if p:find("/") then
        target = full_path:sub(#pat.source_dir + 2) -- strip source_dir + "/"
      else
        target = name
      end
      if target and target:match(lua_pattern) then
        matched = not pat.negate -- negation patterns un-ignore
      end
    end
  end
  return matched
end

return M
