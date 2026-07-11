local util = require("filebuf.util")

local M = {}

--- Parse the entire buffer in one pass, computing the full filesystem
--- path for every entry via an indent stack.  No persistent state needed.
---@param buf number
---@return table[]  list of { name, type, path, indent, lnum }
function M.parse_buffer(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local root = vim.b[buf].filebuf_root
  local entries = {}

  -- Stack of { indent, path } — the ancestry chain.  A directory pushes
  -- onto the stack; when indent decreases we pop until the top is a true
  -- ancestor (indent < current).
  local stack = {} -- { indent = number, path = string }

  for lnum = 1, #lines do
    local line = lines[lnum]
    if line == "" then goto continue end

    local name, is_dir = util.parse_line(line)
    if name == "" then goto continue end

    local indent = util.indent_level(line)

    -- Placeholder entry for an unloaded directory — serves only to
    -- enable fold creation.  Skip normal path reconstruction.
    if name == "\226\128\166" then -- "…" (U+2026)
      while #stack > 0 and stack[#stack].indent >= indent do
        table.remove(stack)
      end
      local parent = #stack > 0 and stack[#stack].path or root
      table.insert(entries, {
        name = "\226\128\166",
        type = "placeholder",
        path = parent .. "/.",
        indent = indent,
        is_placeholder = true,
        lnum = lnum,
      })
      goto continue
    end

    -- Split name on "/" so that "dir/subfile" expands into a synthetic
    -- dir entry and a child entry.  Intermediate segments are always
    -- directories; only the final segment inherits the trailing-slash
    -- flag from the line.
    local name_parts = {}
    for part in name:gmatch("[^/]+") do
      table.insert(name_parts, part)
    end
    if #name_parts == 0 then goto continue end

    for i, part in ipairs(name_parts) do
      -- Only the last segment keeps the original is_dir flag;
      -- intermediate segments are always directories.
      local part_is_dir = (i < #name_parts) or is_dir
      -- First segment keeps the line's original indent; subsequent
      -- segments nest one level deeper.
      local part_indent = indent + (i - 1)

      -- Pop entries that are at or deeper than the current indent.
      while #stack > 0 and stack[#stack].indent >= part_indent do
        table.remove(stack)
      end

      local parent = #stack > 0 and stack[#stack].path or root
      local part_path = parent .. "/" .. part

      if part_is_dir then
        table.insert(stack, { indent = part_indent, path = part_path })
      end

      table.insert(entries, {
        name = part,
        type = part_is_dir and "dir" or "file",
        path = part_path,
        indent = part_indent,
        lnum = lnum,
      })
    end

    ::continue::
  end

  return entries
end

return M
