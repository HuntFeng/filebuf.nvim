local state = require("filebuf.state")
local util = require("filebuf.util")
local parser = require("filebuf.parser")

local M = {}

--- Namespace for git-related extmarks so we can clear only our own
--- marks without disturbing others.
local git_ns = vim.api.nvim_create_namespace("filebuf-git")

--- Define highlight groups for git statuses.  `default = true` ensures
--- user overrides in their colorscheme take precedence.
function M.define_git_highlights()
  local groups = {
    FilebufGitAdded     = { fg = "#98c379" },
    FilebufGitModified  = { fg = "#e5c07b" },
    FilebufGitDeleted   = { fg = "#e06c75" },
    FilebufGitUntracked = { fg = "#61afef" },
    FilebufGitConflict  = { fg = "#c678dd" },
    FilebufGitRenamed   = { fg = "#56b6c2" },
  }
  for name, def in pairs(groups) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", def, { default = true }))
  end
end

--- Unquote a path from git status --porcelain output.  Git wraps
--- paths that contain special characters (spaces, tabs, newlines,
--- non-ASCII bytes, etc.) in double quotes and uses C-style escaping
--- (\n, \t, \\, \") inside them.
---@param path string
---@return string
local function unquote_git_path(path)
  if path:sub(1, 1) == '"' and path:sub(-1) == '"' then
    path = path:sub(2, -2)
    path = path:gsub("\\n", "\n")
    path = path:gsub("\\t", "\t")
    path = path:gsub("\\r", "\r")
    path = path:gsub('\\"', '"')
    path = path:gsub("\\\\", "\\")
  end
  return path
end

--- Run `git status --porcelain` in `root` and return a map of
--- filesystem path → { index, worktree } status codes.
--- Returns nil when the directory is not inside a git repo or git is
--- not available.
---@param root string
---@return table|nil
local function get_git_status_map(root)
  local cmd = string.format(
    "git -C %s status --porcelain --ignored=matching --untracked-files=all",
    vim.fn.shellescape(root)
  )
  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end

  local status_map = {}
  for line in output:gmatch("[^\r\n]+") do
    local x = line:sub(1, 1)
    local y = line:sub(2, 2)
    local filename = unquote_git_path(line:sub(4))

    -- Handle renames: "R  old -> new"
    -- The "->" arrow and both paths may be quoted separately when
    -- either path contains special characters, e.g.
    -- R  "old path" -> "new path"
    if x == "R" then
      local arrow = filename:find(" -> ")
      if arrow then
        filename = filename:sub(arrow + 4)
      end
      -- Unquote again for the new-name portion in case it was
      -- individually quoted inside the combined rename string.
      filename = unquote_git_path(filename)
    end

    local path = root .. "/" .. filename
    status_map[path] = { index = x, worktree = y }
  end

  return status_map
end

--- Convert a git-porcelain status pair to a display character and
--- highlight-group name.  Worktree status takes priority over index
--- status because it reflects the current on-disk state.
---@param s table  { index, worktree }
---@return string|nil char      single-letter status indicator
---@return string|nil hl_group
local function porcelain_to_display(s)
  local x, y = s.index, s.worktree

  -- Worktree status > index status
  local code
  if y ~= " " then
    code = y
  elseif x ~= " " then
    code = x
  else
    return nil
  end

  if code == "?" then return "U", "FilebufGitUntracked" end
  if code == "A" then return "A", "FilebufGitAdded" end
  if code == "M" then return "M", "FilebufGitModified" end
  if code == "D" then return "D", "FilebufGitDeleted" end
  if code == "R" then return "R", "FilebufGitRenamed" end
  if code == "U" then return "C", "FilebufGitConflict" end

  return nil
end

--- Look up the git status for a single entry.
--- Only returns a status for entries that appear directly in git-status
--- output (i.e. files with changes).  Directory names are not colored by
--- git status — the Directory highlight group always wins.
---@param entry table       parsed buffer entry
---@param status_map table  map from get_git_status_map
---@return string|nil char
---@return string|nil hl_group
local function get_entry_git_status(entry, status_map)
  if not status_map then
    return nil
  end

  -- Direct match: the entry's path appears verbatim in git status.
  -- Directories only appear in rare cases (e.g. untracked dirs); for
  -- those we still show the status indicator but don't change the name
  -- color (handled in apply_git_extmarks).
  local s = status_map[entry.path]
  if s then
    return porcelain_to_display(s)
  end

  return nil
end

--- Apply git-status extmarks to every entry in `buf`.  Entries with
--- no git status are left unadorned.  Existing git extmarks are
--- cleared before re-applying.
---@param buf  number
---@param root string  root directory (used to run git status)
function M.apply_git_extmarks(buf, root)
  vim.api.nvim_buf_clear_namespace(buf, git_ns, 0, -1)

  if not state.config.git_status then
    return
  end

  local status_map = get_git_status_map(root)
  if not status_map then
    return
  end

  local entries = parser.parse_buffer(buf)
  for _, entry in ipairs(entries) do
    local char, hl = get_entry_git_status(entry, status_map)
    if char then
      -- Column range covering the filename portion of the line.
      -- Use indent_str to convert depth-level to actual character offset.
      local name_start = #util.indent_str(entry.indent)
      local suffix = entry.type == "dir" and 1 or 0 -- trailing "/"
      local name_end = name_start + #entry.name + suffix

      -- For directories we only add the status indicator as virtual
      -- text; the name itself keeps its Directory coloring.  For files
      -- and links the name is colored with the git status highlight.
      local extmark_opts = {
        virt_text = { { " " .. char, hl } },
      }
      if entry.type ~= "dir" then
        extmark_opts.end_col = name_end
        extmark_opts.hl_group = hl
      end
      vim.api.nvim_buf_set_extmark(buf, git_ns, entry.lnum - 1, name_start, extmark_opts)
    end
  end
end

return M
