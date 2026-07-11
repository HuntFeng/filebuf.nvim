local state = require("filebuf.state")

local M = {}

--- Report validation errors via vim.diagnostic (inline markers) and a
--- single vim.notify summary.
---@param buf    number
---@param errors table[]  { lnum, message }
function M.report_errors(buf, errors)
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
function M.apply_ops(ops)
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
  if not state.config.permanent_delete and #to_delete > 0 then
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
    local na = select(2, a.path:gsub("/", "/"))
    local nb = select(2, b.path:gsub("/", "/"))
    if na ~= nb then
      return na < nb -- shallower paths first
    end
    -- Directories before files at the same depth
    return a.type == "dir" and b.type ~= "dir"
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

return M
