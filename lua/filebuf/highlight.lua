local util = require("filebuf.util")

local M = {}

--- Namespace for hidden-file extmarks.
local hidden_ns = vim.api.nvim_create_namespace("filebuf-hidden")

--- Namespace for directory-name extmarks.
local dir_ns = vim.api.nvim_create_namespace("filebuf-dir")

--- Define highlight groups for hidden-file dimming.
function M.define_hidden_highlights()
  local groups = {
    FilebufHiddenFile = { fg = "#5c6370" },
    FilebufHiddenDir  = { fg = "#5c6370" },
  }
  for name, def in pairs(groups) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", def, { default = true }))
  end
end

--- Create FilebufFoldLine: Normal's foreground on Normal's background.
--- Used by winhighlight to override Folded on the filebuf window.  We
--- intentionally do NOT use Directory's fg — extmarks on directory names
--- provide the correct per-entry coloring even on folded lines.
function M.define_filebuf_highlights()
  -- nvim_get_hl is available since Neovim 0.9
  -- if not pcall(vim.api.nvim_get_hl, 0, { name = "Normal" }) then
  --   vim.api.nvim_set_hl(0, "FilebufFoldLine", { link = "Normal", default = true })
  --   return
  -- end
  --
  -- local function hl_attr(name, attr)
  --   local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name })
  --   return ok and hl and hl[attr] or nil
  -- end
  --
  -- -- local normal_fg = hl_attr("Directory", "fg")
  -- local normal_fg = nil
  -- local normal_bg = hl_attr("Directory", "bg")
  --
  -- if normal_fg or normal_bg then
  --   local attrs = { default = true }
  --   if normal_fg then attrs.fg = normal_fg end
  --   if normal_bg then attrs.bg = normal_bg end
  --   vim.api.nvim_set_hl(0, "FilebufFoldLine", attrs)
  -- else
  --   vim.api.nvim_set_hl(0, "FilebufFoldLine", { link = "Directory", default = true })
  -- end
end

--- Apply extmarks to color directory entry names.
--- Works with entries from either read_dir_recursive (sequential, no lnum)
--- or parse_buffer (may have gaps, has lnum field).
---@param buf     number
---@param entries table[]  flat list (from read_dir_recursive or parse_buffer)
function M.apply_dir_extmarks(buf, entries)
  vim.api.nvim_buf_clear_namespace(buf, dir_ns, 0, -1)

  for lnum, entry in ipairs(entries) do
    if entry.type == "dir" and not entry.is_hidden and not entry.is_ignored then
      local line = entry.lnum or lnum
      local name_start = #util.indent_str(entry.indent)
      local name_end = name_start + #entry.name + 1 -- include trailing "/"
      vim.api.nvim_buf_set_extmark(buf, dir_ns, line - 1, name_start, {
        end_col = name_end,
        hl_group = "Directory",
      })
    end
  end
end

--- Apply dimmed highlighting to hidden / ignored file and directory names.
---@param buf     number
---@param entries table[]  flat list from read_dir_recursive (with is_hidden,
---                        is_ignored, indent, name, type fields)
function M.apply_hidden_extmarks(buf, entries)
  vim.api.nvim_buf_clear_namespace(buf, hidden_ns, 0, -1)

  for lnum, entry in ipairs(entries) do
    if entry.is_hidden or entry.is_ignored then
      local name_start = #util.indent_str(entry.indent)
      local suffix = entry.type == "dir" and 1 or 0
      local name_end = name_start + #entry.name + suffix
      local hl = entry.type == "dir" and "FilebufHiddenDir" or "FilebufHiddenFile"
      vim.api.nvim_buf_set_extmark(buf, hidden_ns, lnum - 1, name_start, {
        end_col = name_end,
        hl_group = hl,
      })
    end
  end
end

return M
