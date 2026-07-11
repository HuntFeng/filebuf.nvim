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
  if level <= 0 then return "" end
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

--- Build the display line for an entry. Directories get a trailing slash.
---@param entry  table  { name, type, path, indent? }
---@return string
function M.format_line(entry)
  local prefix = M.indent_str(entry.indent or 0)
  local suffix = entry.type == "dir" and "/" or ""
  -- Escape control characters so nvim_buf_set_lines doesn't reject the line.
  -- Uses shell $'...' notation so the original name can be recovered.
  local name = entry.name:gsub("[\n\r\t]", function(c)
    return ({ ["\n"] = "$'\\n'", ["\r"] = "$'\\r'", ["\t"] = "$'\\t'" })[c]
  end)
  return prefix .. name .. suffix
end

--- Parse a display line: strip leading whitespace, detect trailing-slash dir marker.
---@param line string
---@return string name      cleaned name (no indent, no trailing slash)
---@return boolean is_dir   true if the line ends with "/"
function M.parse_line(line)
  local name = line:match("^%s*(.+)") or ""
  local is_dir = name:sub(-1) == "/"
  if is_dir then
    name = name:sub(1, -2)
  end
  -- Reverse the $'...' escaping applied in format_line.
  name = name:gsub("%$'\\n'", "\n"):gsub("%$'\\r'", "\r"):gsub("%$'\\t'", "\t")
  return name, is_dir
end

return M
