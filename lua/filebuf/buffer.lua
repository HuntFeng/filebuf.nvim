local util = require("filebuf.util")
local parser = require("filebuf.parser")

local M = {}

--- Insert `entries` into `buf` after `after_line`.  Indent is taken
--- from each entry's `.indent` field (set by read_dir_recursive).
--- Returns the number of lines inserted.
---@param buf        number
---@param entries    table[]
---@param after_line number  0-indexed line to insert after (0 = top)
---@return number
function M.insert_entries(buf, entries, after_line)
  local lines = {}
  for _, entry in ipairs(entries) do
    table.insert(lines, util.format_line(entry))
  end
  vim.api.nvim_buf_set_lines(buf, after_line, after_line, false, lines)
  return #lines
end

--- Create manual folds so that each directory line *includes* its
--- descendants (not just the children).  Nested directories get their
--- own inner folds.
---@param buf number
function M.create_folds(buf)
  local entries = parser.parse_buffer(buf)
  if #entries == 0 then return end

  -- Gather every directory line with its indent level.
  local dirs = {} -- { lnum, indent }
  for _, e in ipairs(entries) do
    if e.type == "dir" then
      table.insert(dirs, { lnum = e.lnum, indent = e.indent })
    end
  end

  -- Sort by indent descending so inner (deeper) folds are created
  -- before outer ones.  This prevents outer folds from absorbing inner
  -- folds in Neovim's manual-fold model.
  table.sort(dirs, function(a, b)
    return a.indent > b.indent
  end)

  -- For each directory find its last descendant and apply a fold
  -- from the directory line itself through the last descendant.
  for _, d in ipairs(dirs) do
    local end_lnum = d.lnum
    for _, e in ipairs(entries) do
      if e.lnum > d.lnum and e.indent > d.indent then
        end_lnum = e.lnum
      elseif e.lnum > d.lnum and e.indent <= d.indent then
        break
      end
    end
    if end_lnum > d.lnum then
      vim.cmd(string.format("%d,%dfold", d.lnum, end_lnum))
    end
  end
end

--- Custom fold-text callback (called via v:lua.FilebufFoldText).
--- Shows the cleaned entry name and the count of folded lines.
--- Uses strdisplaywidth to convert the line's leading whitespace into an
--- equivalent number of space characters, so the fold text always visually
--- aligns with the unfolded lines regardless of tabstop.
function _G.FilebufFoldText()
  local line = vim.fn.getline(vim.v.foldstart)
  local indent_ws = line:match("^(%s*)") or ""
  local name = line:match("^%s*(.-)%s*$") or line
  local indent = string.rep(" ", vim.fn.strdisplaywidth(indent_ws))
  return indent .. name
end

return M
