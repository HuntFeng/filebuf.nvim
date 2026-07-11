local state = require("filebuf.state")
local parser = require("filebuf.parser")
local fs = require("filebuf.fs")
local buffer = require("filebuf.buffer")
local git = require("filebuf.git")
local highlight = require("filebuf.highlight")

local M = {}

--- Persist the closed-fold set for `dir` by scanning the current buffer.
---@param buf   number
---@param root  string  root directory (key into state._fold_closed)
function M.save_fold_state(buf, root)
  state._fold_closed[root] = {}
  local entries = parser.parse_buffer(buf)
  for _, e in ipairs(entries) do
    if e.type == "dir" and vim.fn.foldclosed(e.lnum) ~= -1 then
      state._fold_closed[root][e.path] = true
    end
  end
end

--- Load the children of an unloaded directory into the buffer.
--- Reads one level from disk, removes the placeholder, inserts children,
--- rebuilds folds, and re-applies extmarks.
---@param buf    number
---@param entry  table   parsed buffer entry for the directory
function M.load_directory(buf, entry)
  local root = vim.b[buf].filebuf_root
  if not root then return end

  -- Initialize loaded set for this root if needed
  if not state._loaded_dirs[root] then
    state._loaded_dirs[root] = {}
  end
  state._loaded_dirs[root][entry.path] = true

  -- Determine the ignore patterns for this directory.  Walk up from
  -- the directory to the root, collecting .ignore/.gitignore patterns.
  -- For simplicity, re-derive by walking the path components.
  local merged_patterns
  -- Try to get patterns from parent via the ignore cache, or compute fresh.
  local parent_path = vim.fn.fnamemodify(entry.path, ":h")
  local ignore_cache = vim.b[buf].filebuf_ignore_cache or {}
  local ancestor_patterns = ignore_cache[parent_path]
  merged_patterns = fs.get_merged_patterns(entry.path, ancestor_patterns)
  -- Cache for children of this directory
  ignore_cache[entry.path] = merged_patterns
  vim.b[buf].filebuf_ignore_cache = ignore_cache

  -- Read immediate children
  local children, _ = fs.read_dir_children(entry.path, entry.indent, ancestor_patterns)

  -- Find and remove the placeholder line (the next line after the dir
  -- entry).  The placeholder sits at indent+1 right after the dir line.
  local lnum = entry.lnum
  local placeholder_lnum = nil
  local all_entries = parser.parse_buffer(buf)
  for _, e in ipairs(all_entries) do
    if e.is_placeholder and e.lnum == lnum + 1 then
      -- Verify it's a child of this directory by checking indent
      if e.indent == entry.indent + 1 then
        placeholder_lnum = e.lnum
        break
      end
    end
  end
  if placeholder_lnum then
    vim.api.nvim_buf_set_lines(buf, placeholder_lnum - 1, placeholder_lnum, false, {})
    -- Adjust lnum if the placeholder was above it (shouldn't be, but be safe)
  end

  -- Insert children after the directory line (lnum is 1-indexed, so it
  -- maps to 0-indexed insert position = lnum).
  if #children > 0 then
    buffer.insert_entries(buf, children, lnum)
  end

  -- Rebuild folds — all directories start closed after create_folds.
  vim.cmd("silent! normal! zE")
  buffer.create_folds(buf)

  -- Open the fold for the expanded directory so children are visible
  -- immediately.  Use normal-mode zo (same mechanism as the fold toggle
  -- in handle_enter) rather than the :Nfoldopen Ex command, which can
  -- fail silently when the fold was just created.
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.cmd("normal! zo")

  -- Re-apply extmarks
  git.apply_git_extmarks(buf, root)
  local updated_entries = parser.parse_buffer(buf)
  highlight.apply_dir_extmarks(buf, updated_entries)
  highlight.apply_hidden_extmarks(buf, updated_entries)

  -- Loading children into the buffer is a view operation, not a user
  -- edit — the buffer should not appear modified.
  vim.bo[buf].modified = false
end

--- Handle <CR> in the filebuf buffer.
function M.handle_enter(buf)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  -- Parse the buffer on demand to resolve the entry at the cursor.
  local entries = parser.parse_buffer(buf)
  local entry = nil
  for _, e in ipairs(entries) do
    if e.lnum == lnum then
      entry = e
      break
    end
  end
  if not entry then return end

  -- Placeholder entries are not actionable — ignore.
  if entry.is_placeholder then return end

  if entry.type == "dir" then
    local root = vim.b[buf].filebuf_root
    local loaded = state._loaded_dirs[root]
        and state._loaded_dirs[root][entry.path]

    if not loaded then
      -- Directory hasn't been loaded yet — read children on demand.
      M.load_directory(buf, entry)
    else
      -- Toggle the indent-based fold at this line.
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      local fold_end = vim.fn.foldclosedend(lnum)
      if fold_end ~= -1 then
        vim.cmd("normal! zo")
      else
        vim.cmd("normal! zc")
      end
    end
    -- Immediately persist the new fold state so it survives
    -- close / reopen and subsequent saves.
    M.save_fold_state(buf, vim.b[buf].filebuf_root)
  else
    -- File or symlink — resolve the real path and open.
    local target = vim.loop.fs_realpath(entry.path) or entry.path
    if vim.fn.filereadable(target) == 1 then
      vim.cmd("edit " .. vim.fn.fnameescape(target))
    else
      vim.notify("Cannot read: " .. entry.path, vim.log.levels.WARN)
    end
  end
end

return M
