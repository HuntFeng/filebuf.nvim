local M = {}

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
function M.compute_diff(buf_entries, disk_entries)
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

  ------------------------------------------------------------------
  -- Phase 1: exact-path match -------------------------------------
  ------------------------------------------------------------------
  local buf_unmatched = {}
  for _, be in ipairs(buf_entries) do
    local de = disk_by_path[be.path]
    if de then
      if (de.type == "dir") ~= (be.type == "dir") then
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
        if (best.type == "dir") ~= (be.type == "dir") then
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

return M
