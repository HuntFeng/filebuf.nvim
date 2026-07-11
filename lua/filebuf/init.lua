local M = {}

----------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------

--- Module-level cache: buf → { [lnum] = { name, type, path } }
--- Uses weak keys so entries evaporate when the buffer is wiped.
local buf_entries = setmetatable({}, { __mode = "k" })

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

----------------------------------------------------------------------
-- Buffer line ↔ entry metadata
----------------------------------------------------------------------

--- Get the entry map for a buffer (lazily created).
---@param buf number
---@return table  { [lnum] = entry }
local function get_map(buf)
  local map = buf_entries[buf]
  if not map then
    map = {}
    buf_entries[buf] = map
  end
  return map
end

--- Shift line-indexed entries when lines are inserted or deleted.
---@param buf   number
---@param after_line number  0-indexed line after which the change happened
---@param delta number  positive = inserted N lines, negative = removed N lines
local function shift_map(buf, after_line, delta)
  local map = buf_entries[buf]
  if not map then
    return
  end

  if delta > 0 then
    -- Shift entries at or below after_line+1 down by delta
    for lnum = max_key(map), after_line + 1, -1 do
      if map[lnum] then
        map[lnum + delta] = map[lnum]
        map[lnum] = nil
      end
    end
  elseif delta < 0 then
    -- Remove entries in the deleted range and shift remaining up
    local remove_start = after_line + 1
    local remove_end = after_line - delta -- delta is negative (e.g. -3)
    for lnum = remove_start, remove_end do
      map[lnum] = nil
    end
    for lnum = remove_end + 1, max_key(map) do
      if map[lnum] then
        map[lnum + delta] = map[lnum]
        map[lnum] = nil
      end
    end
  end
end

----------------------------------------------------------------------
-- Programmatic-change tracking — used to suppress user-edit handlers
-- when the plugin itself modifies the buffer.
----------------------------------------------------------------------

--- Per-buffer flags: true while the plugin is mutating buffer lines.
local programmatic = setmetatable({}, { __mode = "k" })

--- Per-buffer flag: true while insert mode is active.
local in_insert = setmetatable({}, { __mode = "k" })

--- Get the maximum key in a table (0 if empty).
local function max_key(t)
  local m = 0
  for k in pairs(t) do
    if type(k) == "number" and k > m then
      m = k
    end
  end
  return m
end

--- Shift map entries down by `count` starting at 1-indexed `at_lnum`.
--- Used after user inserts lines.
---@param buf     number
---@param at_lnum number  1-indexed first line that should shift down
---@param count   number  positive line count
local function shift_map_down(buf, at_lnum, count)
  local map = buf_entries[buf]
  if not map then return end
  for lnum = max_key(map), at_lnum, -1 do
    if map[lnum] then
      map[lnum + count] = map[lnum]
      map[lnum] = nil
    end
  end
end

--- Shift map entries up after deleting `count` lines starting at 1-indexed `at_lnum`.
--- Returns the entries that were removed (so callers can delete them from disk).
---@param buf     number
---@param at_lnum number  1-indexed first deleted line
---@param count   number  positive line count
---@return table[]  removed entries
local function shift_map_up(buf, at_lnum, count)
  local map = buf_entries[buf]
  if not map then return {} end
  -- Collect entries in the deleted range before removing them
  local removed = {}
  for lnum = at_lnum, at_lnum + count - 1 do
    if map[lnum] then
      table.insert(removed, map[lnum])
    end
    map[lnum] = nil
  end
  -- Shift remaining entries up
  local max = max_key(map)
  for lnum = at_lnum + count, max do
    if map[lnum] then
      map[lnum - count] = map[lnum]
      map[lnum] = nil
    end
  end
  return removed
end

--- Get the entry at a specific line.
---@param buf  number
---@param lnum number  1-indexed
---@return table|nil
local function get_entry_at(buf, lnum)
  return get_map(buf)[lnum]
end

--- Walk upward from `lnum` to find the parent directory path.
---@param buf  number
---@param lnum number  1-indexed line
---@return string  parent directory path
local function get_parent_dir(buf, lnum)
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  local current_indent = #(line:match("^(\t*)") or "")

  for i = lnum - 1, 1, -1 do
    local above = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if #above > 0 then
      local above_indent = #(above:match("^(\t*)") or "")
      if above_indent < current_indent then
        local entry = get_entry_at(buf, i)
        if entry and entry.type == "dir" then
          return entry.path
        elseif entry and entry.type == "link" then
          local real = vim.loop.fs_realpath(entry.path)
          if real and vim.fn.isdirectory(real) == 1 then
            return real
          end
        end
        break
      end
    end
  end

  return vim.b[buf].filebuf_root
end

--- Parse a display line: strip indent, detect trailing-slash dir marker.
---@param line string
---@return string name      cleaned name (no indent, no trailing slash)
---@return boolean is_dir   true if the line ends with "/"
local function parse_line(line)
  local name = line:match("^\t*(.+)") or ""
  local is_dir = name:sub(-1) == "/"
  if is_dir then
    name = name:sub(1, -2)
  end
  return name, is_dir
end

--- Create a file or directory on disk from a user-added buffer line.
--- When `apply` is false (or nil), only the in-memory map is updated;
--- the actual filesystem operation is deferred until `apply` is true.
---@param buf   number
---@param lnum  number  1-indexed
---@param line  string  the full display line
---@param apply boolean|nil  whether to execute the filesystem operation
local function create_entry_from_line(buf, lnum, line, apply)
  local name, is_dir = parse_line(line)
  if name == "" then return end

  local parent = get_parent_dir(buf, lnum)
  local path = parent .. "/" .. name

  -- Always update the in-memory map so the buffer remains functional
  -- (navigation, folds, parent resolution, etc.).
  get_map(buf)[lnum] = { name = name, type = (is_dir and "dir" or "file"), path = path }

  if not apply then return end

  if is_dir then
    local ok, err = pcall(vim.loop.fs_mkdir, path, 493) -- 0755
    if not ok then
      vim.notify("filebuf: cannot create dir – " .. (err or path), vim.log.levels.ERROR)
    end
  else
    local fd, err = vim.loop.fs_open(path, "w", 420) -- 0644
    if not fd then
      vim.notify("filebuf: cannot create file – " .. (err or path), vim.log.levels.ERROR)
      return
    end
    vim.loop.fs_close(fd)
  end
end

--- Delete the on-disk file or directory backing `entry`.
--- Directories are removed recursively.
--- When `apply` is false (or nil), the filesystem is left untouched.
---@param entry table  { name, type, path }
---@param apply boolean|nil
local function delete_entry(entry, apply)
  if not apply then return end

  if entry.type == "dir" then
    -- vim.fn.delete with "rf" handles recursive directory removal.
    -- pcall returns true + result on success; vim.fn.delete returns 0 on success.
    local ok, result = pcall(vim.fn.delete, entry.path, "rf")
    if not ok or result ~= 0 then
      vim.notify("filebuf: cannot delete dir – " .. (result or entry.path), vim.log.levels.ERROR)
    end
  else
    local ok, err = pcall(vim.loop.fs_unlink, entry.path)
    if not ok then
      vim.notify("filebuf: cannot delete – " .. (err or entry.path), vim.log.levels.ERROR)
    end
  end
end

--- Rename the on-disk file/dir backing `entry` to `new_name`.
--- The in-memory entry is always updated; the filesystem operation is
--- skipped when `apply` is false (or nil).
---@param entry    table   { name, type, path }
---@param new_name string  cleaned name (no trailing slash)
---@param is_dir   boolean
---@param apply    boolean|nil
local function rename_entry(entry, new_name, is_dir, apply)
  local old_path = entry.path
  local parent = vim.fn.fnamemodify(old_path, ":h")
  local new_path = parent .. "/" .. new_name

  -- Always update in-memory fields so the buffer stays consistent.
  entry.name = new_name
  entry.path = new_path
  if is_dir then
    entry.type = "dir"
  else
    entry.type = "file"
  end

  if not apply then return true end

  local ok, err = pcall(vim.loop.fs_rename, old_path, new_path)
  if not ok then
    vim.notify("filebuf: cannot rename – " .. (err or old_path), vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Process line-range changes from nvim_buf_attach on_lines.
--- (Does NOT rely on a `lines` parameter from the callback — fetches
---  buffer content manually for portability across Neovim versions.)
---
--- We shift the line→entry map so positions stay roughly correct
--- between edits (needed by `get_parent_dir` during reconciliation),
--- but we do NOT create, rename, or delete entries here.  That work is
--- done by `full_reconcile` (triggered by TextChanged / InsertLeave).
---@param buf       number
---@param firstline number  0-indexed
---@param lastline  number  0-indexed, exclusive
---@param linedata  number  line-count delta
---@param preview   boolean  true during inccommand preview
local function on_lines_handler(buf, firstline, lastline, linedata, preview)
  if preview or programmatic[buf] then return end

  if linedata > 0 then
    shift_map_down(buf, firstline + 1, linedata)
  elseif linedata < 0 then
    shift_map_up(buf, firstline + 1, -linedata)
  end
  -- For linedata == 0 (in-place edit), we intentionally do nothing:
  -- let full_reconcile detect the rename via TextChanged.
end

--- Apply the buffer contents to the filesystem — create, rename, and
--- delete entries so the disk matches what the user sees in the buffer.
--- Called by the BufWriteCmd handler when the user types :w.
---
--- Unlike `full_reconcile` (which diffs the buffer against the in-memory
--- map), this function reads the *actual filesystem* via `read_dir_recursive`
--- so it correctly detects changes even after the map has been rebuilt.
---@param buf number
local function apply_to_filesystem(buf)
  local root = vim.b[buf].filebuf_root

  -- Snapshot what actually exists on disk right now.
  local disk_entries = read_dir_recursive(root)
  local by_path = {}
  for _, e in ipairs(disk_entries) do
    by_path[e.path] = e
  end

  local total = vim.api.nvim_buf_line_count(buf)
  for lnum = 1, total do
    local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
    local name, is_dir = parse_line(line)
    if name == "" then goto continue_apply end

    local parent = get_parent_dir(buf, lnum)
    local path = parent .. "/" .. name

    if by_path[path] then
      -- Already exists on disk — nothing to do.
      by_path[path] = nil -- consumed
    else
      -- Not on disk at this path.  Check whether an on-disk entry in
      -- the same parent directory was renamed.
      local matched = false
      for old_path, old_entry in pairs(by_path) do
        if vim.fn.fnamemodify(old_path, ":h") == parent then
          local ok, err = pcall(vim.loop.fs_rename, old_path, path)
          if not ok then
            vim.notify("filebuf: cannot rename – " .. (err or old_path), vim.log.levels.ERROR)
          end
          by_path[old_path] = nil
          matched = true
          break
        end
      end
      if not matched then
        -- Truly new entry — create on disk.
        if is_dir then
          local ok, err = pcall(vim.loop.fs_mkdir, path, 493) -- 0755
          if not ok then
            vim.notify("filebuf: cannot create dir – " .. (err or path), vim.log.levels.ERROR)
          end
        else
          local fd, err = vim.loop.fs_open(path, "w", 420) -- 0644
          if not fd then
            vim.notify("filebuf: cannot create file – " .. (err or path), vim.log.levels.ERROR)
          else
            vim.loop.fs_close(fd)
          end
        end
      end
    end
    ::continue_apply::
  end

  -- Any disk entries still in `by_path` were deleted from the buffer.
  -- Delete deepest paths first so children are removed before parents.
  local to_delete = {}
  for path, entry in pairs(by_path) do
    table.insert(to_delete, { path = path, type = entry.type })
  end
  table.sort(to_delete, function(a, b) return #a.path > #b.path end)
  for _, item in ipairs(to_delete) do
    if item.type == "dir" then
      pcall(vim.fn.delete, item.path, "rf")
    else
      pcall(vim.loop.fs_unlink, item.path)
    end
  end
end

--- Full reconciliation pass — walks every buffer line, rebuilds the
--- line→entry map, and optionally applies filesystem changes.
--- When `apply` is false (or nil) only the in-memory map is updated.
---@param buf   number
---@param apply boolean|nil
local function full_reconcile(buf, apply)
  if programmatic[buf] then return end

  local map = get_map(buf)
  local total = vim.api.nvim_buf_line_count(buf)

  -- Build a set of existing map entries indexed by path so we can
  -- re-home them when line numbers shift.
  local by_path = {}
  for _, entry in pairs(map) do
    by_path[entry.path] = entry
  end

  -- Clear the old line→entry map; we rebuild it from scratch.
  for lnum in pairs(map) do
    map[lnum] = nil
  end

  for lnum = 1, total do
    local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
    local name, is_dir = parse_line(line)
    if name == "" then goto continue_reconcile end

    local parent = get_parent_dir(buf, lnum)
    local path = parent .. "/" .. name

    -- Try to re-home an existing entry whose path matches.
    local entry = by_path[path]
    if entry then
      -- Existing entry placed at a (possibly new) line — update type in
      -- case a trailing slash was added or removed.
      entry.type = is_dir and "dir" or "file"
      map[lnum] = entry
      by_path[path] = nil -- consumed
    else
      -- No existing entry at this path — could be a rename or a creation.
      -- Try to find an old entry whose name changed: look through remaining
      -- by_path entries for one in the same parent directory.
      local matched = false
      for old_path, old_entry in pairs(by_path) do
        if vim.fn.fnamemodify(old_path, ":h") == parent then
          -- Rename: old entry at this parent, new name
          rename_entry(old_entry, name, is_dir, apply)
          map[lnum] = old_entry
          by_path[old_path] = nil
          matched = true
          break
        end
      end
      if not matched then
        -- Truly new entry — create (or queue creation).
        create_entry_from_line(buf, lnum, line, apply)
      end
    end
    ::continue_reconcile::
  end

  -- Remaining entries in by_path were deleted from the buffer.
  -- Delete them from disk (or queue deletion).
  for _, entry in pairs(by_path) do
    delete_entry(entry, apply)
  end
end

--- Store entries into the buffer map at the given line numbers.
---@param buf      number
---@param entries  table[]
---@param first    number  1-indexed line of the first entry
local function store_entries(buf, entries, first)
  local map = get_map(buf)
  for i, entry in ipairs(entries) do
    map[first + i - 1] = entry
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
  -- Build display lines
  local lines = {}
  for _, entry in ipairs(entries) do
    table.insert(lines, format_line(entry))
  end

  programmatic[buf] = true
  -- Insert into buffer (after_line is 0-indexed in the API)
  vim.api.nvim_buf_set_lines(buf, after_line, after_line, false, lines)
  programmatic[buf] = false

  -- Update metadata
  shift_map(buf, after_line, #lines)
  store_entries(buf, entries, after_line + 1)

  return #lines
end

--- Create manual folds so that each directory line *includes* its
--- descendants (not just the children).  Nested directories get their
--- own inner folds.
---@param buf number
local function create_folds(buf)
  local map = get_map(buf)
  local total = vim.api.nvim_buf_line_count(buf)
  if total == 0 then
    return
  end

  -- Gather every directory line with its indent level.
  local dirs = {} -- { lnum, indent }
  for lnum = 1, total do
    local entry = map[lnum]
    if entry and entry.type == "dir" then
      local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
      local indent = #(line:match("^(\t*)") or "")
      table.insert(dirs, { lnum = lnum, indent = indent })
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
    for lnum = d.lnum + 1, total do
      local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
      if #line == 0 then break end
      local li = #(line:match("^(\t*)") or "")
      if li <= d.indent then break end
      end_lnum = lnum
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

--- Handle <CR> in the filebuf buffer.
local function handle_enter(buf)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local entry = get_entry_at(buf, lnum)
  if not entry then
    return
  end

  if entry.type == "dir" then
    -- Toggle the indent-based fold at this line.
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    local fold_end = vim.fn.foldclosedend(lnum)
    if fold_end ~= -1 then
      vim.cmd("normal! zo")
    else
      vim.cmd("normal! zc")
    end
  elseif entry.type == "file" or entry.type == "link" then
    -- For symlinks, follow them; if the target is a file, open it
    if entry.type == "link" then
      local real = vim.loop.fs_realpath(entry.path)
      if real then
        if vim.fn.filereadable(real) == 1 then
          vim.cmd("edit " .. vim.fn.fnameescape(real))
          return
        end
      end
    end

    if vim.fn.filereadable(entry.path) == 1 then
      vim.cmd("edit " .. vim.fn.fnameescape(entry.path))
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
---@param dir string|nil  root directory (default: cwd)
function M.open(dir)
  dir = dir or vim.fn.getcwd()

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
  -- Close all folds so the user starts with a clean overview.
  vim.cmd("silent! %foldclose!")

  -- Attach buffer change listener for structural line changes
  -- (insertions / deletions).  This keeps the line→entry map in sync.
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(_, _, firstline, lastline, linedata, preview)
      on_lines_handler(buf, firstline, lastline, linedata, preview)
    end,
  })

  local group = vim.api.nvim_create_augroup("filebuf_edit_" .. buf, { clear = true })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = buf,
    callback = function()
      in_insert[buf] = true
    end,
  })

  -- On InsertLeave, reconcile the in-memory line→entry map so the buffer
  -- stays functional (navigation, folds, etc.).  Filesystem operations are
  -- deferred until the user saves with :w.
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = buf,
    callback = function()
      in_insert[buf] = false
      full_reconcile(buf, false) -- map-only, no filesystem ops
    end,
  })

  -- TextChanged catches normal-mode edits that might not trigger on_lines
  -- on every Neovim version (e.g. r, ~, x, J).
  vim.api.nvim_create_autocmd("TextChanged", {
    group = group,
    buffer = buf,
    callback = function()
      if not in_insert[buf] then
        full_reconcile(buf, false) -- map-only, no filesystem ops
      end
    end,
  })

  -- BufWriteCmd intercepts :w and applies the buffer contents to the
  -- filesystem.  We diff against the actual on-disk state (not the
  -- in-memory map) so that creates, renames, and deletes are all detected.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    callback = function()
      apply_to_filesystem(buf)
      vim.bo[buf].modified = false
    end,
  })

  vim.bo[buf].modified = false
end

--- Setup entry point for lazy.nvim. Registers user commands.
function M.setup()
  vim.api.nvim_create_user_command("Filebuf", function()
    M.open()
  end, { desc = "Open filebuf listing buffer" })
end

return M
