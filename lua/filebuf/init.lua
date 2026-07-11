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
}

--- Persisted fold-closed state, keyed by root directory.
--- Each value is a set of filesystem paths whose folds were closed.
--- Survives buffer close/reopen so the user's fold preferences stick.
M._fold_closed = {}

----------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------

--- Read a directory using native stat calls.  Returns entries sorted
--- directories-first, then alphabetically (case-insensitive).
---@param dir string
---@return table[]  list of { name, type, path }
local function read_dir(dir)
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

  return entries
end

--- Recursively read a directory tree, returning a flat list with indent
--- levels. Uses cycle detection via real paths to handle symlinks safely.
---@param dir string
---@param max_depth number|nil
---@param current_depth number
---@param visited table|nil  set of real paths already visited (cycle detection)
---@return table[]  list of { name, type, path, indent }
local function read_dir_recursive(dir, max_depth, current_depth, visited)
  current_depth = current_depth or 0
  max_depth = max_depth or 20 -- safety limit for deep / cyclic hierarchies
  visited = visited or {}

  -- Cycle detection via real path
  local real = vim.loop.fs_realpath(dir) or dir
  if visited[real] or current_depth > max_depth then
    return {}
  end
  visited[real] = true

  local entries = read_dir(dir)
  local result = {}
  for _, entry in ipairs(entries) do
    entry.indent = current_depth
    table.insert(result, entry)
    if entry.type == "dir" then
      local children = read_dir_recursive(entry.path, max_depth, current_depth + 1, visited)
      vim.list_extend(result, children)
    elseif entry.type == "link" then
      -- Follow symlinks that point to directories
      local link_real = vim.loop.fs_realpath(entry.path)
      if link_real and vim.fn.isdirectory(link_real) == 1 then
        local children = read_dir_recursive(link_real, max_depth, current_depth + 1, visited)
        vim.list_extend(result, children)
      end
    end
  end
  return result
end

--- Build the display line for an entry. Directories get a trailing slash.
---@param entry  table  { name, type, path, indent? }
---@return string
local function format_line(entry)
  local prefix = string.rep("\t", entry.indent or 0)
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

    local indent = #(line:match("^(%s*)") or "")

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
function _G.FilebufFoldText()
  local line = vim.fn.getline(vim.v.foldstart)
  local indent = line:match("^(\t*)") or ""
  local name = line:match("^\t*(.-)%s*$") or line
  local count = vim.v.foldend - vim.v.foldstart
  return indent .. name .. "  (" .. count .. ")"
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

        -- 6. Snapshot the current fold state so we can restore it
        --    after the buffer is reloaded from disk.
        save_fold_state(buf, dir)

        -- 7. Reload the buffer from the filesystem so formatting is
        --    consistent — indentation is canonical, no orphaned children,
        --    and every directory gets a proper fold.
        local fresh = read_dir_recursive(dir)
        local fresh_lines = {}
        for _, entry in ipairs(fresh) do
          table.insert(fresh_lines, format_line(entry))
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, fresh_lines)

        -- 8. Rebuild folds from the fresh tree.  create_folds produces
        --    closed folds, so open everything first, then re-close only
        --    the directories the user had closed before the save.
        --    New directories stay open.
        vim.cmd("silent! normal! zE")
        create_folds(buf)
        vim.cmd("silent! %foldopen!")
        do
          local post_entries = parse_buffer(buf)
          for _, e in ipairs(post_entries) do
            if e.type == "dir" and M._fold_closed[dir][e.path] then
              vim.cmd(string.format("%dfoldclose", e.lnum))
            end
          end
        end

        vim.bo[buf].modified = false
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
  M.config = vim.tbl_deep_extend("force", M.config, opts)

  vim.api.nvim_create_user_command("Filebuf", function()
    M.open()
  end, { desc = "Open filebuf listing buffer" })
end

return M
