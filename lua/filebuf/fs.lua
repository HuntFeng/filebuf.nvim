local state = require("filebuf.state")
local ignore = require("filebuf.ignore")

local M = {}

--- Read a directory using native stat calls.  Returns entries sorted
--- directories-first, then alphabetically (case-insensitive).
---@param dir string
---@param ignore_patterns? table[]  { raw, source_dir } patterns from ignore files
---@return table[]  list of { name, type, path }
function M.read_dir(dir, ignore_patterns)
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
  -- Hidden/ignored entries are tagged for later highlighting.
  local filtered = {}
  for _, entry in ipairs(entries) do
    if entry.name ~= ".ignore" then
      local is_dotfile = entry.name:sub(1, 1) == "."
      local is_ignored = state.config.respect_ignore
          and ignore_patterns
          and #ignore_patterns > 0
          and ignore.matches_ignore(entry.path, entry.name, ignore_patterns, entry.type == "dir")
      if is_dotfile then
        entry.is_hidden = true
      end
      if is_ignored then
        entry.is_ignored = true
      end
      if (is_dotfile or is_ignored) and not state.config.show_hidden then
        goto skip_entry
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

  return entries
end

--- Quick check: does `dir` have at least one visible child entry?
--- Uses only vim.fn.readdir (no fs_stat), so it is an order of magnitude
--- cheaper than read_dir.  Applies dotfile filtering and ignore-pattern
--- basename matching; directory-only patterns (trailing /) are
--- conservatively skipped since we cannot determine the entry type
--- without fs_stat.
---@param dir string
---@param ignore_patterns? table[]
---@return boolean
function M.has_visible_children(dir, ignore_patterns)
  local items = vim.fn.readdir(dir)
  if vim.v.shell_error ~= 0 then return false end
  -- When show_hidden is on, the first non-.ignore entry means "yes".
  -- No need to evaluate ignore patterns — everything is visible.
  if state.config.show_hidden then
    for _, name in ipairs(items) do
      if name ~= ".ignore" then return true end
    end
    return false
  end
  -- show_hidden off: only count entries that are not dotfiles and not ignored.
  for _, name in ipairs(items) do
    if name ~= ".ignore" then
      local is_dotfile = name:sub(1, 1) == "."
      local is_ignored = state.config.respect_ignore
          and ignore_patterns
          and #ignore_patterns > 0
          and ignore.matches_ignore(dir .. "/" .. name, name, ignore_patterns, false)
      if not (is_dotfile or is_ignored) then
        return true
      end
    end
  end
  return false
end

--- Merge ignore patterns from ancestor directories with any local
--- .ignore / .gitignore files found in `dir`.  Extracted from
--- read_dir_recursive so it can be reused by expand_dir.
---@param dir string
---@param ancestor_patterns? table[]
---@return table[] merged_patterns
function M.get_merged_patterns(dir, ancestor_patterns)
  local merged = {}
  if not state.config.respect_ignore then return merged end
  if ancestor_patterns then
    for _, p in ipairs(ancestor_patterns) do
      table.insert(merged, p)
    end
  end
  for _, name in ipairs({ ".ignore", ".gitignore" }) do
    local ignore_path = dir .. "/" .. name
    if vim.loop.fs_stat(ignore_path) then
      local local_patterns = ignore.parse_ignore_file(ignore_path)
      for _, p in ipairs(local_patterns) do
        table.insert(merged, { raw = p.raw, negate = p.negate, source_dir = dir })
      end
    end
  end
  return merged
end

--- Read a single directory level (no recursion) and append placeholder
--- entries for any subdirectory that has visible children.  Returns the
--- flat list of entries *and* the merged ignore patterns for this
--- directory (so the caller can cache them for later expand_dir calls).
---@param dir string
---@param parent_indent number
---@param ancestor_patterns? table[]
---@return table[] entries
---@return table[] merged_patterns
function M.read_dir_children(dir, parent_indent, ancestor_patterns)
  local merged = M.get_merged_patterns(dir, ancestor_patterns)
  local entries = M.read_dir(dir, merged)
  local result = {}
  for _, entry in ipairs(entries) do
    entry.indent = parent_indent + 1
    table.insert(result, entry)
    if entry.type == "dir" then
      if M.has_visible_children(entry.path, merged) then
        table.insert(result, {
          name = "\226\128\166", -- "…" (U+2026) as UTF-8 bytes
          type = "placeholder",
          path = entry.path .. "/.",
          indent = parent_indent + 2,
          is_placeholder = true,
        })
      end
    elseif entry.type == "link" then
      local link_real = vim.loop.fs_realpath(entry.path)
      if link_real and vim.fn.isdirectory(link_real) == 1
         and M.has_visible_children(link_real, merged) then
        table.insert(result, {
          name = "\226\128\166", -- "…"
          type = "placeholder",
          path = entry.path .. "/.",
          indent = parent_indent + 2,
          is_placeholder = true,
        })
      end
    end
  end
  return result, merged
end

--- Read the directory tree, recursing only into directories present in
--- `loaded_set`.  Used by compute_diff and refresh_buffer to get the
--- on-disk state for only the loaded portion of the tree.
---@param root string
---@param loaded_set table   { [dir_path] = true }
---@return table[]  flat list with indent fields
function M.read_dir_loaded(root, loaded_set)
  local result = {}
  local visited = {}

  local function recurse(dir, depth, ancestor_patterns)
    if depth > 20 then return end
    local real = vim.loop.fs_realpath(dir) or dir
    if visited[real] then return end
    visited[real] = true

    local merged = M.get_merged_patterns(dir, ancestor_patterns)
    local entries = M.read_dir(dir, merged)
    for _, entry in ipairs(entries) do
      entry.indent = depth
      table.insert(result, entry)

      if entry.type == "dir" and loaded_set[entry.path] then
        recurse(entry.path, depth + 1, merged)
      elseif entry.type == "link" then
        local link_real = vim.loop.fs_realpath(entry.path)
        if link_real and vim.fn.isdirectory(link_real) == 1
           and loaded_set[entry.path] then
          recurse(link_real, depth + 1, merged)
        end
      end
    end
  end

  recurse(root, 0, nil)
  return result
end

--- Recursively read a directory tree, returning a flat list with indent
--- levels. Uses cycle detection via real paths to handle symlinks safely.
---@param dir string
---@param max_depth number|nil
---@param current_depth number
---@param visited table|nil  set of real paths already visited (cycle detection)
---@param ancestor_patterns? table[]  { raw, source_dir } patterns from parents
---@return table[]  list of { name, type, path, indent }
function M.read_dir_recursive(dir, max_depth, current_depth, visited, ancestor_patterns)
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
  local merged_patterns = M.get_merged_patterns(dir, ancestor_patterns)

  local entries = M.read_dir(dir, merged_patterns)
  local result = {}
  for _, entry in ipairs(entries) do
    entry.indent = current_depth
    table.insert(result, entry)
    if entry.type == "dir" then
      local children = M.read_dir_recursive(entry.path, max_depth, current_depth + 1, visited, merged_patterns)
      vim.list_extend(result, children)
    elseif entry.type == "link" then
      -- Follow symlinks that point to directories
      local link_real = vim.loop.fs_realpath(entry.path)
      if link_real and vim.fn.isdirectory(link_real) == 1 then
        local children = M.read_dir_recursive(link_real, max_depth, current_depth + 1, visited, merged_patterns)
        vim.list_extend(result, children)
      end
    end
  end
  return result
end

--- Recursively collect a directory tree into a flat list, recursing only
--- into directories present in `loaded_set`.  Unloaded-but-non-empty
--- directories get a placeholder child (U+2026) so the fold indicator
--- appears.  This is the shared tree-walking logic used by both M.open
--- and refresh_buffer.
---@param collect_dir string
---@param indent number
---@param ancestor_patterns? table[]
---@param loaded_set table     { [dir_path] = true }
---@param ignore_cache table   buffer-local cache of merged patterns
---@return table[]  flat list of entries with indent fields
function M.collect_tree(collect_dir, indent, ancestor_patterns, loaded_set, ignore_cache)
  local merged = M.get_merged_patterns(collect_dir, ancestor_patterns)
  -- Cache patterns so subsequent expand_dir calls can retrieve them
  ignore_cache[collect_dir] = merged

  local dir_entries = M.read_dir(collect_dir, merged)
  local result = {}
  for _, entry in ipairs(dir_entries) do
    entry.indent = indent
    table.insert(result, entry)

    if entry.type == "dir" then
      if loaded_set[entry.path] then
        local children = M.collect_tree(entry.path, indent + 1, merged, loaded_set, ignore_cache)
        vim.list_extend(result, children)
      elseif M.has_visible_children(entry.path, merged) then
        table.insert(result, {
          name = "\226\128\166", -- "…"
          type = "placeholder",
          path = entry.path .. "/.",
          indent = indent + 1,
          is_placeholder = true,
        })
      end
    elseif entry.type == "link" then
      local link_real = vim.loop.fs_realpath(entry.path)
      if link_real and vim.fn.isdirectory(link_real) == 1 then
        if loaded_set[entry.path] then
          local children = M.collect_tree(link_real, indent + 1, merged, loaded_set, ignore_cache)
          vim.list_extend(result, children)
        elseif M.has_visible_children(link_real, merged) then
          table.insert(result, {
            name = "\226\128\166", -- "…"
            type = "placeholder",
            path = entry.path .. "/.",
            indent = indent + 1,
            is_placeholder = true,
          })
        end
      end
    end
  end
  return result
end

return M
