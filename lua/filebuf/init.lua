local M = {}

--- Plugin configuration (set via setup()).
---@class filebuf.Config
---@field permanent_delete boolean  when false, deleted entries are moved to a trash directory
---@field auto_focus_current_file boolean  when true, focus the tree on the file
---                                        that was open before :Filebuf
---                                        (default: true)
M.config = {
  permanent_delete = true,
  auto_focus_current_file = true,
  --- when true, show git status indicators (A, M, D, …) next to entries
  --- that have uncommitted changes (default: true)
  git_status = true,
  --- when true, use tab characters for indentation; when false, use
  --- indent_width spaces per indent level (default: auto-detected from
  --- the user's global expandtab setting)
  use_tabs = nil,
  --- number of spaces per indent level, only used when use_tabs = false
  --- (default: auto-detected from the user's global shiftwidth)
  indent_width = nil,
  --- when false, entries whose name starts with "." are hidden from the
  --- buffer (default: false)
  show_hidden = false,
  --- when true, .ignore files in directories are read and their patterns
  --- are used to filter entries. The .ignore file itself is never hidden.
  --- (default: true)
  respect_ignore = true,
}

--- Persisted fold-closed state, keyed by root directory.
--- Each value is a set of filesystem paths whose folds were closed.
--- Survives buffer close/reopen so the user's fold preferences stick.
M._fold_closed = {}

----------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------

--- Parse a .ignore file and return a list of raw pattern strings.
--- Supports # comments, blank lines, and trailing / for dir-only patterns.
---@param path string  full filesystem path to the .ignore file
---@return string[]
local function parse_ignore_file(path)
  local lines = vim.fn.readfile(path)
  if type(lines) ~= "table" then return {} end
  local patterns = {}
  for _, line in ipairs(lines) do
    -- Strip leading/trailing whitespace
    line = line:match("^%s*(.-)%s*$") or line
    -- Skip blank lines and comments
    if line ~= "" and line:sub(1, 1) ~= "#" then
      table.insert(patterns, line)
    end
  end
  return patterns
end

--- Check if an entry matches any ignore pattern.
--- Supports: * wildcard (any sequence of chars), trailing / (dir-only),
--- and path-based patterns (containing "/").
---@param full_path string    full filesystem path of the entry
---@param name      string    entry basename
---@param patterns  table[]   { raw = string, source_dir = string }
---@param is_dir    boolean   whether the entry is a directory
---@return boolean
local function matches_ignore(full_path, name, patterns, is_dir)
  if not patterns or #patterns == 0 then return false end
  for _, pat in ipairs(patterns) do
    local dir_only = false
    local p = pat.raw
    -- Trailing "/" means match only directories
    if p:sub(-1) == "/" then
      dir_only = true
      p = p:sub(1, -2)
    end
    if dir_only and not is_dir then
      goto continue
    end
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
      return true
    end
    ::continue::
  end
  return false
end

--- Build the indent prefix for a given depth level.
---@param level number
---@return string
local function indent_str(level)
  if level <= 0 then return "" end
  if M.config.use_tabs then
    return string.rep("\t", level)
  else
    return string.rep(" ", level * M.config.indent_width)
  end
end

--- Compute the indent depth level from a buffer line's leading whitespace.
---@param line string
---@return number
local function indent_level(line)
  local ws = line:match("^(%s*)") or ""
  if M.config.use_tabs then
    local _, count = ws:gsub("\t", "")
    return count
  else
    return math.floor(#ws / M.config.indent_width)
  end
end

--- Read a directory using native stat calls.  Returns entries sorted
--- directories-first, then alphabetically (case-insensitive).
---@param dir string
---@param ignore_patterns? table[]  { raw, source_dir } patterns from ignore files
---@return table[]  list of { name, type, path }
local function read_dir(dir, ignore_patterns)
  local files = vim.fn.readdir(dir)
  if vim.v.shell_error ~= 0 then
    return {
      { name = "(error reading directory)", type = "error", path = dir }
    }
  end

  local entries = {}
  for _, name in ipairs(files) do
    local path = (dir == "/" and "/" .. name) or (dir .. "/" .. name)
    local stat = vim.loop.fs_stat(path)
    if stat then
      local ftype = vim.fn.getftype(path) or "file"

      -- Resolve type label
      local type_label
      if ftype == "dir" then
        type_label = "dir"
      elseif ftype == "link" then
        type_label = "link"
      else
        type_label = "file"
      end

      table.insert(entries, {
        name = name,
        type = type_label,
        path = path,
      })
    end
  end

  -- Filter hidden files and ignore-matched entries.
  -- The .ignore file itself is never filtered; .gitignore is hidden
  -- like other dotfiles (but its patterns are still read from disk).
  -- When show_hidden is true, ignore patterns are also bypassed.
  -- Hidden entries are tagged with is_hidden for later highlighting.
  local hidden_count = 0
  local filtered = {}
  for _, entry in ipairs(entries) do
    if entry.name ~= ".ignore" then
      local is_dotfile = entry.name:sub(1, 1) == "."
      local is_ignored = M.config.respect_ignore
          and ignore_patterns
          and #ignore_patterns > 0
          and matches_ignore(entry.path, entry.name, ignore_patterns, entry.type == "dir")
      if is_dotfile or is_ignored then
        entry.is_hidden = true
        hidden_count = hidden_count + 1
        if not M.config.show_hidden then
          goto skip_entry
        end
      end
    end
    table.insert(filtered, entry)
    ::skip_entry::
  end
  entries = filtered

  -- Sort: dirs first, then links, then files; alpha within each group
  table.sort(entries, function(a, b)
    local prio = { dir = 1, link = 2, file = 3, error = 4 }
    local pa = prio[a.type] or 5
    local pb = prio[b.type] or 5
    if pa ~= pb then
      return pa < pb
    end
    return a.name:lower() < b.name:lower()
  end)

  return entries, hidden_count
end

--- Recursively read a directory tree, returning a flat list with indent
--- levels. Uses cycle detection via real paths to handle symlinks safely.
---@param dir string
---@param max_depth number|nil
---@param current_depth number
---@param visited table|nil  set of real paths already visited (cycle detection)
---@param ancestor_patterns? table[]  { raw, source_dir } patterns from parents
---@return table[]  list of { name, type, path, indent }
---@return number   total count of hidden entries in the tree
local function read_dir_recursive(dir, max_depth, current_depth, visited, ancestor_patterns)
  current_depth = current_depth or 0
  max_depth = max_depth or 20 -- safety limit for deep / cyclic hierarchies
  visited = visited or {}

  -- Cycle detection via real path
  local real = vim.loop.fs_realpath(dir) or dir
  if visited[real] or current_depth > max_depth then
    return {}
  end
  visited[real] = true

  -- Merge ignore patterns: carry forward ancestors, add local .ignore
  -- and .gitignore if present.  Each pattern stores its source_dir so
  -- that path-based patterns (containing "/") can be matched against
  -- the entry's path relative to the .ignore file's directory.
  local merged_patterns = {}
  if M.config.respect_ignore then
    if ancestor_patterns then
      for _, p in ipairs(ancestor_patterns) do
        table.insert(merged_patterns, p)
      end
    end
    for _, name in ipairs({ ".ignore", ".gitignore" }) do
      local ignore_path = dir .. "/" .. name
      if vim.loop.fs_stat(ignore_path) then
        local local_patterns = parse_ignore_file(ignore_path)
        for _, raw in ipairs(local_patterns) do
          table.insert(merged_patterns, { raw = raw, source_dir = dir })
        end
      end
    end
  end

  local entries, local_hidden = read_dir(dir, merged_patterns)
  local total_hidden = local_hidden
  local result = {}
  for _, entry in ipairs(entries) do
    entry.indent = current_depth
    table.insert(result, entry)
    if entry.type == "dir" then
      local children, child_hidden = read_dir_recursive(entry.path, max_depth, current_depth + 1, visited, merged_patterns)
      entry.has_hidden = child_hidden > 0
      total_hidden = total_hidden + child_hidden
      vim.list_extend(result, children)
    elseif entry.type == "link" then
      -- Follow symlinks that point to directories
      local link_real = vim.loop.fs_realpath(entry.path)
      if link_real and vim.fn.isdirectory(link_real) == 1 then
        local children, child_hidden = read_dir_recursive(link_real, max_depth, current_depth + 1, visited, merged_patterns)
        entry.has_hidden = child_hidden > 0
        total_hidden = total_hidden + child_hidden
        vim.list_extend(result, children)
      end
    end
  end
  return result, total_hidden
end

--- Build the display line for an entry. Directories get a trailing slash.
---@param entry  table  { name, type, path, indent? }
---@return string
local function format_line(entry)
  local prefix = indent_str(entry.indent or 0)
  local suffix = entry.type == "dir" and "/" or ""
  return prefix .. entry.name .. suffix
end

--- Parse a display line: strip leading whitespace, detect trailing-slash dir marker.
---@param line string
---@return string name      cleaned name (no indent, no trailing slash)
---@return boolean is_dir   true if the line ends with "/"
local function parse_line(line)
  local name = line:match("^%s*(.+)") or ""
  local is_dir = name:sub(-1) == "/"
  if is_dir then
    name = name:sub(1, -2)
  end
  return name, is_dir
end

----------------------------------------------------------------------
-- Buffer parser — derives structured entries from the raw buffer text
----------------------------------------------------------------------

--- Parse the entire buffer in one pass, computing the full filesystem
--- path for every entry via an indent stack.  No persistent state needed.
---@param buf number
---@return table[]  list of { name, type, path, indent, lnum }
local function parse_buffer(buf)
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

    local name, is_dir = parse_line(line)
    if name == "" then goto continue end

    local indent = indent_level(line)

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

----------------------------------------------------------------------
-- Diff engine — compares buffer entries against on-disk state
----------------------------------------------------------------------

--- Compare the buffer's desired state with the actual filesystem and
--- produce a set of operations that would bring the disk in line with
--- the buffer.
---
--- Rename detection is name-based: an unmatched buffer entry is paired
--- with an unmatched disk entry that shares the same name, preferring a
--- match in the same parent directory.
---
---@param buf_entries  table[]  parsed buffer entries (from parse_buffer)
---@param disk_entries  table[]  entries from read_dir_recursive
---@return table  { unchanged, renamed, created, deleted, errors }
local function compute_diff(buf_entries, disk_entries)
  -- Index disk entries by path for O(1) lookup
  local disk_by_path = {}
  for _, de in ipairs(disk_entries) do
    disk_by_path[de.path] = de
  end

  local unchanged = {}
  local renamed = {}   -- { old = disk_entry, new = buf_entry }
  local created = {}
  local deleted = {}
  local errors = {}

  local consumed = {}  -- set of disk paths already matched

  -- Helper: "dir" is the only directory type; "file" and "link" are both
  -- non-directory and should not flag a type mismatch against each other.
  local function is_dir_type(t)
    return t == "dir"
  end

  ------------------------------------------------------------------
  -- Phase 1: exact-path match -------------------------------------
  ------------------------------------------------------------------
  local buf_unmatched = {}
  for _, be in ipairs(buf_entries) do
    local de = disk_by_path[be.path]
    if de then
      if is_dir_type(de.type) ~= is_dir_type(be.type) then
        -- Type mismatch on an otherwise-unchanged entry.
        -- e.g. user accidentally deleted the trailing "/" from a dir,
        -- or added "/" to a file.
        local detail = be.type == "dir"
            and " (extra trailing '/')"
            or " (missing trailing '/')"
        table.insert(errors, {
          lnum = be.lnum,
          message = string.format(
            "'%s' is a %s on disk but shown as %s in buffer%s",
            be.name, de.type, be.type, detail
          ),
        })
      end
      table.insert(unchanged, be)
      consumed[de.path] = true
    else
      table.insert(buf_unmatched, be)
    end
  end

  ------------------------------------------------------------------
  -- Phase 2: name-based rename matching ---------------------------
  ------------------------------------------------------------------

  -- Collect unmatched disk entries
  local disk_unmatched = {}
  for _, de in ipairs(disk_entries) do
    if not consumed[de.path] then
      table.insert(disk_unmatched, de)
    end
  end

  -- Index unmatched disk entries by name
  local disk_by_name = {}
  for _, de in ipairs(disk_unmatched) do
    if not disk_by_name[de.name] then
      disk_by_name[de.name] = {}
    end
    table.insert(disk_by_name[de.name], de)
  end

  local renamed_disk_paths = {} -- set of disk paths consumed by renames
  for _, be in ipairs(buf_unmatched) do
    local candidates = disk_by_name[be.name]
    if candidates then
      -- Prefer same-parent matches to avoid false positives when
      -- multiple directories contain files with the same name.
      local best = nil
      local be_parent = vim.fn.fnamemodify(be.path, ":h")
      for _, de in ipairs(candidates) do
        if not renamed_disk_paths[de.path] then
          local de_parent = vim.fn.fnamemodify(de.path, ":h")
          if de_parent == be_parent then
            best = de
            break
          end
        end
      end
      -- Fallback: any unmatched disk entry with the same name
      if not best then
        for _, de in ipairs(candidates) do
          if not renamed_disk_paths[de.path] then
            best = de
            break
          end
        end
      end

      if best then
        if is_dir_type(best.type) ~= is_dir_type(be.type) then
          table.insert(errors, {
            lnum = be.lnum,
            message = string.format(
              "'%s' rename changes type: %s on disk -> %s in buffer",
              be.name, best.type, be.type
            ),
          })
        end
        table.insert(renamed, { old = best, new = be })
        renamed_disk_paths[best.path] = true
      else
        table.insert(created, be)
      end
    else
      table.insert(created, be)
    end
  end

  ------------------------------------------------------------------
  -- Phase 3: remaining disk entries are deletes -------------------
  ------------------------------------------------------------------
  for _, de in ipairs(disk_unmatched) do
    if not renamed_disk_paths[de.path] then
      table.insert(deleted, de)
    end
  end

  return {
    unchanged = unchanged,
    renamed = renamed,
    created = created,
    deleted = deleted,
    errors = errors,
  }
end

----------------------------------------------------------------------
-- Operation applicator — executes the diff results on the filesystem
----------------------------------------------------------------------

--- Report validation errors via vim.diagnostic (inline markers) and a
--- single vim.notify summary.
---@param buf    number
---@param errors table[]  { lnum, message }
local function report_errors(buf, errors)
  vim.diagnostic.reset(nil, buf)
  if #errors == 0 then return end

  local diags = {}
  for _, err in ipairs(errors) do
    table.insert(diags, {
      lnum = (err.lnum or 1) - 1, -- 0-indexed
      col = 0,
      severity = vim.diagnostic.severity.ERROR,
      message = err.message,
      source = "filebuf",
    })
  end
  vim.diagnostic.set(nil, buf, diags)
  vim.notify(
    string.format("filebuf: %d error(s) — fix and save again", #errors),
    vim.log.levels.ERROR
  )
end

--- Apply the computed operations to the filesystem.
---
--- Execution order:
---   1. Renames — move files before their source directories are deleted.
---      Target parent directories are created first when needed.
---   2. Deletes — deepest path first (children before parents).
---   3. Creates — sorted by depth (shallowest first) with `mkdir -p`
---      semantics so intermediate directories are always created
---      automatically.
---@param ops table  result of compute_diff()
local function apply_ops(ops)
  -- 1. Renames (before deletes so source files are moved out before
  --    their parent dirs are recursively removed).
  for _, r in ipairs(ops.renamed) do
    -- Ensure the target parent directory exists before renaming.
    local target_parent = vim.fn.fnamemodify(r.new.path, ":h")
    vim.fn.mkdir(target_parent, "p")
    local ok, err = pcall(vim.loop.fs_rename, r.old.path, r.new.path)
    if not ok then
      vim.notify("filebuf: cannot rename – " .. (err or r.old.path), vim.log.levels.ERROR)
    end
  end

  -- 2. Deletes (deepest first)
  local to_delete = {}
  for _, de in ipairs(ops.deleted) do
    table.insert(to_delete, de)
  end
  table.sort(to_delete, function(a, b) return #a.path > #b.path end)

  -- When permanent_delete is disabled, prepare a timestamped trash
  -- directory so that every save gets its own recovery folder.
  local trash_dir = nil
  if not M.config.permanent_delete and #to_delete > 0 then
    trash_dir = string.format(
      "/tmp/filebuf-trash/%s",
      os.date("%Y_%m_%d_%H_%M_%S")
    )
    vim.fn.mkdir(trash_dir, "p")
  end

  for _, de in ipairs(to_delete) do
    if trash_dir then
      -- Move to trash instead of deleting.
      local dest = trash_dir .. "/" .. de.name
      -- Avoid name collisions inside the trash folder.
      local n = 1
      while vim.loop.fs_stat(dest) do
        n = n + 1
        dest = string.format("%s/%s.%d", trash_dir, de.name, n)
      end
      local ok, err = pcall(vim.loop.fs_rename, de.path, dest)
      if not ok then
        vim.notify("filebuf: cannot trash – " .. (err or de.path), vim.log.levels.ERROR)
      end
    elseif de.type == "dir" then
      pcall(vim.fn.delete, de.path, "rf")
    else
      pcall(vim.loop.fs_unlink, de.path)
    end
  end

  -- 3. Creates — sort by depth so parents are always created before
  --    children, and ensure every parent directory exists.
  table.sort(ops.created, function(a, b)
    local _, na = a.path:gsub("/", "")
    local _, nb = b.path:gsub("/", "")
    if na ~= nb then
      return na < nb -- shallower paths first
    end
    -- Directories before files at the same depth
    if a.type == "dir" and b.type ~= "dir" then return true end
    if a.type ~= "dir" and b.type == "dir" then return false end
    return false
  end)
  for _, be in ipairs(ops.created) do
    if be.type == "dir" then
      -- "p" flag creates intermediate directories (mkdir -p).
      local ok, err = pcall(vim.fn.mkdir, be.path, "p")
      if not ok then
        vim.notify("filebuf: cannot create dir – " .. (err or be.path), vim.log.levels.ERROR)
      end
    else
      -- Ensure the parent directory chain exists before creating the file.
      local parent_dir = vim.fn.fnamemodify(be.path, ":h")
      vim.fn.mkdir(parent_dir, "p")
      local fd, err = vim.loop.fs_open(be.path, "w", 420) -- 0644
      if not fd then
        vim.notify("filebuf: cannot create file – " .. (err or be.path), vim.log.levels.ERROR)
      else
        vim.loop.fs_close(fd)
      end
    end
  end
end

----------------------------------------------------------------------
-- Buffer manipulation
----------------------------------------------------------------------

--- Insert `entries` into `buf` after `after_line`.  Indent is taken
--- from each entry's `.indent` field (set by read_dir_recursive).
--- Returns the number of lines inserted.
---@param buf        number
---@param entries    table[]
---@param after_line number  0-indexed line to insert after (0 = top)
---@return number
local function insert_entries(buf, entries, after_line)
  local lines = {}
  for _, entry in ipairs(entries) do
    table.insert(lines, format_line(entry))
  end
  vim.api.nvim_buf_set_lines(buf, after_line, after_line, false, lines)
  return #lines
end

--- Create manual folds so that each directory line *includes* its
--- descendants (not just the children).  Nested directories get their
--- own inner folds.
---@param buf number
local function create_folds(buf)
  local entries = parse_buffer(buf)
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
  local count = vim.v.foldend - vim.v.foldstart
  local indent = string.rep(" ", vim.fn.strdisplaywidth(indent_ws))
  return indent .. name .. "  (" .. count .. ")"
end

----------------------------------------------------------------------
-- Git status indicators (extmarks)
----------------------------------------------------------------------

--- Namespace for git-related extmarks so we can clear only our own
--- marks without disturbing others.
local git_ns = vim.api.nvim_create_namespace("filebuf-git")

--- Define highlight groups for git statuses.  `default = true` ensures
--- user overrides in their colorscheme take precedence.
local function define_git_highlights()
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

--- Run `git status --porcelain` in `root` and return a map of
--- filesystem path → { index, worktree } status codes.
--- Returns nil when the directory is not inside a git repo or git is
--- not available.
---@param root string
---@return table|nil
local function get_git_status_map(root)
  local cmd = string.format(
    "git -C %s status --porcelain --ignored=matching",
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
    local filename = line:sub(4)

    -- Handle renames: "R  old -> new"
    if x == "R" then
      local arrow = filename:find(" -> ")
      if arrow then
        filename = filename:sub(arrow + 4)
      end
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

--- Look up the git status for a single entry.  For directories this
--- propagates child statuses upward: if any descendant has a git
--- status the directory inherits it.
---@param entry table       parsed buffer entry
---@param status_map table  map from get_git_status_map
---@return string|nil char
---@return string|nil hl_group
local function get_entry_git_status(entry, status_map)
  if not status_map then
    return nil
  end

  -- Direct match: the entry's path appears verbatim in git status
  local s = status_map[entry.path]
  if s then
    return porcelain_to_display(s)
  end

  -- For directories, propagate status from any descendant
  if entry.type == "dir" then
    local prefix = entry.path .. "/"
    for path, ps in pairs(status_map) do
      if vim.startswith(path, prefix) then
        return porcelain_to_display(ps)
      end
    end
  end

  return nil
end

--- Apply git-status extmarks to every entry in `buf`.  Entries with
--- no git status are left unadorned.  Existing git extmarks are
--- cleared before re-applying.
---@param buf  number
---@param root string  root directory (used to run git status)
local function apply_git_extmarks(buf, root)
  vim.api.nvim_buf_clear_namespace(buf, git_ns, 0, -1)

  if not M.config.git_status then
    return
  end

  local status_map = get_git_status_map(root)
  if not status_map then
    return
  end

  local entries = parse_buffer(buf)
  for _, entry in ipairs(entries) do
    local char, hl = get_entry_git_status(entry, status_map)
    if char then
      -- Column range covering the filename portion of the line.
      -- Use indent_str to convert depth-level to actual character offset.
      local name_start = #indent_str(entry.indent)
      local suffix = entry.type == "dir" and 1 or 0 -- trailing "/"
      local name_end = name_start + #entry.name + suffix

      vim.api.nvim_buf_set_extmark(buf, git_ns, entry.lnum - 1, name_start, {
        end_col = name_end,
        hl_group = hl,
        virt_text = { { " " .. char, hl } },
      })
    end
  end
end

--- Namespace and highlight groups for hidden-file extmarks.
local hidden_ns = vim.api.nvim_create_namespace("filebuf-hidden")

local function define_hidden_highlights()
  local groups = {
    FilebufHiddenHint = { fg = "#5c6370" },
    FilebufHiddenFile = { fg = "#5c6370" },
    FilebufHiddenDir  = { fg = "#5c6370" },
  }
  for name, def in pairs(groups) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", def, { default = true }))
  end
end

--- Apply extmarks for hidden-content hints and hidden-file coloring.
--- Directory entries with has_hidden get a " (...hidden...)" virt_lines
--- hint on a new line right after the directory's last visible descendant,
--- indented one level deeper than the directory.  This ensures the hint is
--- always visible, including for root-level hidden content.
--- Entries tagged is_hidden get dimmed highlighting on their name.
---@param buf     number
---@param entries table[]  flat list from read_dir_recursive (with is_hidden,
---                        has_hidden, indent, name, type fields)
local function apply_hidden_extmarks(buf, entries)
  vim.api.nvim_buf_clear_namespace(buf, hidden_ns, 0, -1)
  if #entries == 0 then return end

  if not M.config.show_hidden then
    -- Root-level hidden content: check if any top-level entry is hidden
    -- or has hidden descendants.
    local root_has_hidden = false
    for _, entry in ipairs(entries) do
      if entry.indent == 0 and (entry.has_hidden or entry.is_hidden) then
        root_has_hidden = true
        break
      end
    end
    if root_has_hidden then
      local hint_line = indent_str(0) .. "(...hidden...)"
      vim.api.nvim_buf_set_extmark(buf, hidden_ns, #entries - 1, 0, {
        virt_lines = { { { hint_line, "FilebufHiddenHint" } } },
      })
    end

    -- Subdirectory hints: for each directory with has_hidden, find its
    -- last visible descendant and add a virt_lines hint after it.
    for lnum, entry in ipairs(entries) do
      if entry.type == "dir" and entry.has_hidden then
        local last_child = lnum
        for i = lnum + 1, #entries do
          if entries[i].indent > entry.indent then
            last_child = i
          else
            break
          end
        end
        local hint_line = indent_str(entry.indent + 1) .. "(...hidden...)"
        vim.api.nvim_buf_set_extmark(buf, hidden_ns, last_child - 1, 0, {
          virt_lines = { { { hint_line, "FilebufHiddenHint" } } },
        })
      end
    end
  end

  -- Hidden-file coloring
  for lnum, entry in ipairs(entries) do
    if entry.is_hidden then
      local name_start = #indent_str(entry.indent)
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

----------------------------------------------------------------------
-- <CR> handler
----------------------------------------------------------------------

--- Persist the closed-fold set for `dir` by scanning the current buffer.
---@param buf   number
---@param root  string  root directory (key into M._fold_closed)
local function save_fold_state(buf, root)
  M._fold_closed[root] = {}
  local entries = parse_buffer(buf)
  for _, e in ipairs(entries) do
    if e.type == "dir" and vim.fn.foldclosed(e.lnum) ~= -1 then
      M._fold_closed[root][e.path] = true
    end
  end
end

--- Handle <CR> in the filebuf buffer.
local function handle_enter(buf)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  -- Parse the buffer on demand to resolve the entry at the cursor.
  local entries = parse_buffer(buf)
  local entry = nil
  for _, e in ipairs(entries) do
    if e.lnum == lnum then
      entry = e
      break
    end
  end
  if not entry then return end

  if entry.type == "dir" then
    -- Toggle the indent-based fold at this line.
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    local fold_end = vim.fn.foldclosedend(lnum)
    if fold_end ~= -1 then
      vim.cmd("normal! zo")
    else
      vim.cmd("normal! zc")
    end
    -- Immediately persist the new fold state so it survives
    -- close / reopen and subsequent saves.
    save_fold_state(buf, vim.b[buf].filebuf_root)
  else
    -- File or symlink — resolve the real path and open.
    local target = entry.path
    local real = vim.loop.fs_realpath(entry.path)
    if real and real ~= entry.path then
      target = real
    end
    if vim.fn.filereadable(target) == 1 then
      vim.cmd("edit " .. vim.fn.fnameescape(target))
    else
      vim.notify("Cannot read: " .. entry.path, vim.log.levels.WARN)
    end
  end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

--- Re-read the directory tree from disk and refresh the buffer contents.
--- Preserves fold state across the refresh: directories that were open
--- stay open; new directories (e.g. hidden dirs revealed by toggle)
--- remain closed.
---@param buf number  filebuf buffer to refresh
local function refresh_buffer(buf)
  local dir = vim.b[buf].filebuf_root
  if not dir then return end

  -- 1. Snapshot which directories are currently *open* so we can
  --    restore exactly them after the refresh.  save_fold_state also
  --    persists the closed set so fold preferences survive buffer close.
  save_fold_state(buf, dir)
  local open_dirs = {}
  local pre_entries = parse_buffer(buf)
  for _, e in ipairs(pre_entries) do
    if e.type == "dir" and vim.fn.foldclosed(e.lnum) == -1 then
      open_dirs[e.path] = true
    end
  end

  -- 2. Re-read the tree from disk with current config (filtering applied)
  local entries = read_dir_recursive(dir)
  local fresh_lines = {}
  for _, entry in ipairs(entries) do
    table.insert(fresh_lines, format_line(entry))
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, fresh_lines)

  -- 3. Rebuild folds — create_folds produces closed folds for every
  --    directory.  Then re-open only the directories that were open
  --    before the refresh.  New directories (including hidden ones that
  --    just became visible) stay closed.
  vim.cmd("silent! normal! zE")
  create_folds(buf)
  local post_entries = parse_buffer(buf)
  for _, e in ipairs(post_entries) do
    if e.type == "dir" and open_dirs[e.path] then
      vim.cmd(string.format("%dfoldopen", e.lnum))
    end
  end

  -- 4. Refresh git extmarks and hidden-entry hints
  apply_git_extmarks(buf, dir)
  apply_hidden_extmarks(buf, entries)

  vim.bo[buf].modified = false
end

--- Toggle show_hidden and refresh the filebuf buffer.
--- Refuses if the buffer has unsaved changes to prevent data loss.
---@param buf number
local function toggle_hidden(buf)
  -- Guard: prevent data loss if the user has unsaved edits
  if vim.bo[buf].modified then
    vim.notify(
      "filebuf: save or discard changes before toggling hidden files",
      vim.log.levels.WARN
    )
    return
  end

  M.config.show_hidden = not M.config.show_hidden
  refresh_buffer(buf)

  local state = M.config.show_hidden and "shown" or "hidden"
  vim.notify("filebuf: hidden files " .. state, vim.log.levels.INFO)
end

--- Open the filebuf browser. The entire directory tree is loaded
--- recursively with indent-based folding.  Top-level entries are visible;
--- subdirectories are initially folded.  Use `za` or `<CR>` (on a
--- directory) to toggle folds.
---
--- Press <CR> on a file to edit it.
---
--- Changes to the buffer are only applied to the filesystem when you
--- save with `:w`.  Type mismatches (e.g. deleting the trailing "/" from
--- a directory) are flagged as errors and block the save.
---
---@param dir string|nil  root directory (default: cwd)
function M.open(dir)
  dir = dir or vim.fn.getcwd()

  -- Capture the current editing file *before* we create the filebuf
  -- buffer, so we can auto-focus on it after the tree is built.
  local current_file = vim.api.nvim_buf_get_name(0)

  local buf = vim.api.nvim_create_buf(true, true)
  -- Give the buffer a name so :w triggers BufWriteCmd instead of E32.
  vim.api.nvim_buf_set_name(buf, "filebuf://" .. dir)
  vim.b[buf].filebuf_root = dir
  vim.bo[buf].filetype = "filebuf"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "acwrite"

  -- Buffer-local keymaps
  vim.keymap.set("n", "<CR>", function()
    handle_enter(buf)
  end, { buffer = buf, desc = "Open file / toggle directory fold" })
  vim.keymap.set("n", "q", function()
    save_fold_state(buf, dir)
    vim.api.nvim_buf_delete(buf, { force = true })
  end, { buffer = buf, desc = "Close filebuf" })
  vim.keymap.set("n", "H", function()
    toggle_hidden(buf)
  end, { buffer = buf, desc = "Toggle hidden files" })

  -- Populate the buffer with the full recursive tree
  local entries = read_dir_recursive(dir)
  if #entries > 0 then
    insert_entries(buf, entries, 0)
  end

  -- Manual folding: each directory + its descendants form a fold.
  -- Closed initially so only top-level entries are visible.
  vim.api.nvim_set_current_buf(buf)
  vim.wo.foldmethod = "manual"
  vim.wo.foldenable = true
  vim.wo.foldcolumn = "1"
  vim.wo.foldtext = "v:lua.FilebufFoldText()"
  -- Replace default +/- fold-column glyphs with triangles.
  local fc = vim.wo.fillchars or ""
  vim.wo.fillchars = fc .. "foldopen:▼,foldclose:▶"
  create_folds(buf)

  -- Restore saved fold state, or close everything on first open.
  if M._fold_closed[dir] then
    -- create_folds produces closed folds.  Open everything first,
    -- then re-close only the directories the user had closed before.
    vim.cmd("silent! %foldopen!")
    local post_entries = parse_buffer(buf)
    for _, e in ipairs(post_entries) do
      if e.type == "dir" and M._fold_closed[dir][e.path] then
        vim.cmd(string.format("%dfoldclose", e.lnum))
      end
    end
  else
    -- First open: start with a clean overview.
    vim.cmd("silent! %foldclose!")
  end

  -- Auto-focus on the file that was being edited before :Filebuf.
  if M.config.auto_focus_current_file
    and current_file ~= ""
    and vim.startswith(current_file, dir:sub(-1) == "/" and dir or (dir .. "/"))
  then
    local target = vim.fn.resolve(current_file)
    local focus_entries = parse_buffer(buf)
    local target_lnum = nil
    for _, e in ipairs(focus_entries) do
      if vim.fn.resolve(e.path) == target then
        target_lnum = e.lnum
        break
      end
    end
    if target_lnum then
      -- Open ancestor folds from outermost to innermost so the
      -- file is visible.  Collect dirs above the target line whose
      -- indent is less than the target's.
      local target_indent = nil
      for _, e in ipairs(focus_entries) do
        if e.lnum == target_lnum then
          target_indent = e.indent
          break
        end
      end
      if target_indent then
        local ancestors = {}
        for _, e in ipairs(focus_entries) do
          if e.type == "dir" and e.lnum < target_lnum and e.indent < target_indent then
            -- Keep only the closest ancestor at each indent depth
            -- (the last one seen before the target).
            ancestors[e.indent] = e.lnum
          end
        end
        -- Open from outermost (lowest indent) to innermost.
        local sorted = {}
        for _, lnum in pairs(ancestors) do
          table.insert(sorted, lnum)
        end
        table.sort(sorted)
        for _, lnum in ipairs(sorted) do
          pcall(vim.cmd, string.format("%dfoldopen", lnum))
        end
      end
      vim.api.nvim_win_set_cursor(0, { target_lnum, 0 })
      vim.cmd("normal! zz")
    end
  end

  -- Apply git-status extmarks after the buffer is fully populated.
  apply_git_extmarks(buf, dir)
  apply_hidden_extmarks(buf, entries)

  -- BufWriteCmd parses the buffer, diffs against the filesystem,
  -- validates, and applies changes.
  local group = vim.api.nvim_create_augroup("filebuf_edit_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    callback = function()
      local ok, result = pcall(function()
        -- 1. Parse the buffer
        local buf_entries = parse_buffer(buf)

        -- 2. Read current filesystem state
        local disk_entries = read_dir_recursive(dir)

        -- 3. Diff
        local ops = compute_diff(buf_entries, disk_entries)

        -- 4. Validate — abort on errors
        if #ops.errors > 0 then
          report_errors(buf, ops.errors)
          error("filebuf: validation failed")
        end

        -- Clear any stale diagnostics from a previous failed save
        vim.diagnostic.reset(nil, buf)

        -- 5. Apply
        apply_ops(ops)

        -- 6. Refresh the buffer from disk — preserves fold state,
        --    rebuilds folds, and refreshes git extmarks.
        refresh_buffer(buf)

        vim.notify("filebuf: saved", vim.log.levels.INFO)
      end)

      -- If pcall caught an unexpected error (not a validation failure),
      -- surface it to the user.
      if not ok and not tostring(result):match("validation failed") then
        vim.notify("filebuf: save error – " .. tostring(result), vim.log.levels.ERROR)
      end
    end,
  })

  vim.bo[buf].modified = false
end

--- Setup entry point for lazy.nvim.  Accepts an optional configuration
--- table (merged into M.config) and registers user commands.
---
---@param opts? filebuf.Config
---
--- Usage (lazy.nvim):
---   {
---     "user/filebuf",
---     dir = "~/path/to/filebuf",
---     opts = { permanent_delete = false },
---     config = true,
---   }
--- Or (init.lua):
---   require("filebuf").setup({ permanent_delete = false })
function M.setup(opts)
  opts = opts or {}

  -- Auto-detect indentation preferences from the user's global config
  -- when not explicitly provided.
  if opts.use_tabs == nil then
    opts.use_tabs = not vim.go.expandtab
  end
  if opts.indent_width == nil then
    local sw = vim.go.shiftwidth
    opts.indent_width = (sw > 0 and sw) or vim.go.tabstop
  end

  M.config = vim.tbl_deep_extend("force", M.config, opts)

  -- Ensure highlight groups exist so users can override them in their
  -- colorscheme before the first buffer is opened.
  define_git_highlights()
  define_hidden_highlights()

  vim.api.nvim_create_user_command("Filebuf", function()
    M.open()
  end, { desc = "Open filebuf listing buffer" })
  vim.api.nvim_create_user_command("FilebufToggleHidden", function()
    -- Find the filebuf buffer in the current tabpage, or fail gracefully
    local buf = vim.api.nvim_get_current_buf()
    if vim.b[buf] and vim.b[buf].filebuf_root then
      toggle_hidden(buf)
    else
      vim.notify("filebuf: not in a filebuf buffer", vim.log.levels.WARN)
    end
  end, { desc = "Toggle visibility of hidden (dot) files in filebuf" })
end

return M
