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

--- Set of directories whose children have been loaded into the buffer.
--- Keyed by root directory; each value is { [dir_path] = true }.
--- A directory not in this set has only a placeholder child in the buffer.
--- Survives buffer refresh but is cleared on toggle_hidden.
M._loaded_dirs = {}

return M
