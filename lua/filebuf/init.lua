-- filebuf — a Neovim file-tree buffer where you edit the tree directly.
--
-- Submodule layout:
--   state.lua      config + persisted state (zero deps)
--   util.lua       indent helpers, line format/parse
--   ignore.lua     .gitignore / .ignore parsing & matching
--   fs.lua         filesystem reads & tree walking
--   parser.lua     buffer → structured entries
--   diff.lua       buffer vs disk diff engine
--   apply.lua      diff → filesystem operations
--   buffer.lua     insert entries, create folds, fold-text callback
--   git.lua        git status porcelain → extmarks
--   highlight.lua  hidden/dir/fold highlight defs → extmarks
--   handlers.lua   <CR> key, fold-state persistence, lazy dir loading

local state = require("filebuf.state")
local util = require("filebuf.util")
local fs = require("filebuf.fs")
local parser = require("filebuf.parser")
local diff = require("filebuf.diff")
local apply = require("filebuf.apply")
local buffer = require("filebuf.buffer")
local git = require("filebuf.git")
local highlight = require("filebuf.highlight")
local handlers = require("filebuf.handlers")

-- The state module doubles as the public module table so that
-- M.config, M._fold_closed, and M._loaded_dirs are accessible
-- both internally (via require("filebuf.state")) and externally
-- (via require("filebuf").config).
local M = state

----------------------------------------------------------------------
-- Internal (not exported)
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
  handlers.save_fold_state(buf, dir)
  local open_dirs = {}
  local pre_entries = parser.parse_buffer(buf)
  for _, e in ipairs(pre_entries) do
    if e.type == "dir" and vim.fn.foldclosed(e.lnum) == -1 then
      open_dirs[e.path] = true
    end
  end

  -- 2. Re-read the tree from disk with current config, respecting the
  --    loaded set: only recurse into directories whose children have
  --    been loaded.  Unloaded directories get placeholders.
  local loaded_set = M._loaded_dirs[dir] or {}
  local ignore_cache = vim.b[buf].filebuf_ignore_cache or {}
  local entries = fs.collect_tree(dir, 0, nil, loaded_set, ignore_cache)
  vim.b[buf].filebuf_ignore_cache = ignore_cache

  local fresh_lines = {}
  for _, entry in ipairs(entries) do
    table.insert(fresh_lines, util.format_line(entry))
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, fresh_lines)

  -- 3. Rebuild folds — create_folds produces closed folds for every
  --    directory.  Then re-open only the directories that were open
  --    before the refresh.  New directories (including hidden ones that
  --    just became visible) stay closed.
  vim.cmd("silent! normal! zE")
  buffer.create_folds(buf)
  local post_entries = parser.parse_buffer(buf)
  for _, e in ipairs(post_entries) do
    if e.type == "dir" and open_dirs[e.path] then
      vim.cmd(string.format("silent! %dfoldopen", e.lnum))
    end
  end
  -- Persist the updated fold state so it survives a subsequent
  -- close / reopen.  This must happen *after* folds are rebuilt,
  -- otherwise newly-revealed directories (e.g. hidden dirs after
  -- a toggle) are missing from the closed set and would all open
  -- on the next :Filebuf.
  handlers.save_fold_state(buf, dir)

  -- 4. Refresh git extmarks, hidden-entry hints, and directory coloring
  git.apply_git_extmarks(buf, dir)
  highlight.apply_hidden_extmarks(buf, entries)
  highlight.apply_dir_extmarks(buf, entries)

  vim.bo[buf].modified = false
end

--- Toggle show_hidden and refresh the filebuf buffer.
--- Refuses if the buffer has unsaved changes to prevent data loss.
--- Preserves the cursor on the same entry across the toggle by resolving
--- the entry path before the refresh and re-locating it afterwards.
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

  -- Capture the entry under the cursor before refreshing so we can
  -- restore the cursor to the same entry after the toggle.
  local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cursor_entry_path = nil
  local pre_entries = parser.parse_buffer(buf)
  for _, e in ipairs(pre_entries) do
    if e.lnum == cursor_lnum then
      cursor_entry_path = e.path
      break
    end
  end

  M.config.show_hidden = not M.config.show_hidden

  -- Clear loaded state so the tree is re-evaluated fresh with the new
  -- show_hidden setting.  Previously expanded directories collapse back
  -- to placeholders; the user can re-expand as needed.
  local dir = vim.b[buf].filebuf_root
  M._loaded_dirs[dir] = {}

  refresh_buffer(buf)

  -- Re-locate the same entry in the refreshed buffer and move the
  -- cursor to its new line.  This naturally accounts for any entries
  -- that were added or removed before the cursor line by the toggle.
  if cursor_entry_path then
    local post_entries = parser.parse_buffer(buf)
    for _, e in ipairs(post_entries) do
      if e.path == cursor_entry_path then
        vim.api.nvim_win_set_cursor(0, { e.lnum, 0 })
        break
      end
    end
  end

  local state_desc = M.config.show_hidden and "shown" or "hidden"
  vim.notify("filebuf: hidden files " .. state_desc, vim.log.levels.INFO)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

--- Open the filebuf browser.  Only root-level entries are loaded eagerly;
--- subdirectory contents are loaded on demand when expanded via <CR>.
--- Top-level entries are visible; subdirectories are initially folded.
--- Changes to the buffer are only applied to the filesystem when you
--- save with `:w`.  Type mismatches (e.g. deleting the trailing "/" from
--- a directory) are flagged as errors and block the save.
---
---@param dir string|nil  root directory (default: cwd)
function M.open(dir)
  dir = dir or vim.fn.getcwd()
  -- Normalize: strip trailing slash for consistent path joining.
  dir = dir:gsub("/$", "")

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

  -- Initialize lazy-loading state
  M._loaded_dirs[dir] = {}
  local loaded_set = M._loaded_dirs[dir]
  vim.b[buf].filebuf_ignore_cache = {}

  -- Pre-load ancestor directories when auto-focusing on the current file
  -- so that the file's entry exists in the buffer.
  if M.config.auto_focus_current_file
    and current_file ~= ""
    and vim.startswith(current_file, dir .. "/")
  then
    local target = vim.fn.resolve(current_file)
    local parent = vim.fn.fnamemodify(target, ":h")
    while parent ~= dir and parent ~= "/" and parent ~= "" do
      loaded_set[parent] = true
      parent = vim.fn.fnamemodify(parent, ":h")
    end
  end

  -- Buffer-local keymaps
  vim.keymap.set("n", "<CR>", function()
    handlers.handle_enter(buf)
  end, { buffer = buf, desc = "Open file / toggle directory fold" })
  vim.keymap.set("n", "q", function()
    handlers.save_fold_state(buf, dir)
    vim.api.nvim_buf_delete(buf, { force = true })
  end, { buffer = buf, desc = "Close filebuf" })
  vim.keymap.set("n", "H", function()
    toggle_hidden(buf)
  end, { buffer = buf, desc = "Toggle hidden files" })

  -- Populate the buffer: collect root-level entries + placeholders for
  -- unloaded subdirectories + recursive children of pre-loaded dirs.
  local entries = fs.collect_tree(dir, 0, nil, loaded_set, vim.b[buf].filebuf_ignore_cache)
  if #entries > 0 then
    buffer.insert_entries(buf, entries, 0)
  end

  -- Manual folding: each directory + its descendants form a fold.
  -- Closed initially so only top-level entries are visible.
  vim.api.nvim_set_current_buf(buf)
  vim.wo.foldmethod = "manual"
  vim.wo.foldenable = true
  vim.wo.foldcolumn = "auto:9"
  vim.wo.foldtext = "v:lua.FilebufFoldText()"
  -- Override the Folded highlight group in this window to suppress
  -- the background color (many colorschemes set a prominent bg).
  -- FilebufFoldLine is created at setup time by reading Directory's
  -- fg and Normal's bg.  A plain link to Directory doesn't work
  -- because winhighlight overlays attributes — Directory typically
  -- sets only fg (bg=NONE), so Folded's background would leak through.
  -- FilebufFoldLine has both fg and bg set, fully replacing Folded.
  vim.wo.winhighlight = "Folded:FilebufFoldLine"
  -- Replace default +/- fold-column glyphs with triangles.
  local fc = vim.wo.fillchars or ""
  vim.wo.fillchars = fc .. "foldopen:▼,foldclose:▶,fold: "
  buffer.create_folds(buf)

  -- Restore saved fold state, or close everything on first open.
  if M._fold_closed[dir] then
    -- create_folds already produced closed folds for every directory.
    -- Instead of opening everything and then re-closing, open only the
    -- directories the user had previously expanded (i.e. those missing
    -- from the closed set).  This way any unaccounted directory (e.g. a
    -- newly-revealed hidden dir) defaults to closed instead of open.
    local post_entries = parser.parse_buffer(buf)
    for _, e in ipairs(post_entries) do
      if e.type == "dir" and not M._fold_closed[dir][e.path] then
        vim.cmd(string.format("silent! %dfoldopen", e.lnum))
      end
    end
  else
    -- First open: start with a clean overview.
    vim.cmd("silent! %foldclose!")
  end

  -- Auto-focus on the file that was being edited before :Filebuf.
  if M.config.auto_focus_current_file
    and current_file ~= ""
    and vim.startswith(current_file, dir .. "/")
  then
    local target = vim.fn.resolve(current_file)
    local focus_entries = parser.parse_buffer(buf)
    local target_lnum, target_indent = nil, nil
    for _, e in ipairs(focus_entries) do
      if vim.fn.resolve(e.path) == target then
        target_lnum = e.lnum
        target_indent = e.indent
        break
      end
    end
    if target_lnum and target_indent then
      -- Open ancestor folds from outermost to innermost so the
      -- file is visible.  Collect dirs above the target line whose
      -- indent is less than the target's.
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
      vim.api.nvim_win_set_cursor(0, { target_lnum, 0 })
      vim.cmd("normal! zz")
    end
  end

  -- Apply git-status extmarks after the buffer is fully populated.
  git.apply_git_extmarks(buf, dir)
  highlight.apply_hidden_extmarks(buf, entries)
  highlight.apply_dir_extmarks(buf, entries)

  -- BufWriteCmd parses the buffer, diffs against the filesystem,
  -- validates, and applies changes.
  local group = vim.api.nvim_create_augroup("filebuf_edit_" .. buf, { clear = true })

  -- Re-apply extmarks whenever the user edits the buffer so that
  -- stale indicators don't linger on deleted or moved lines.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    buffer = buf,
    callback = function()
      git.apply_git_extmarks(buf, dir)
      highlight.apply_dir_extmarks(buf, parser.parse_buffer(buf))
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    callback = function()
      local ok, result = pcall(function()
        -- 1. Parse the buffer, filtering out placeholder entries which
        --    are not real filesystem entries.
        local all_buf_entries = parser.parse_buffer(buf)
        local buf_entries = {}
        for _, e in ipairs(all_buf_entries) do
          if not e.is_placeholder then
            table.insert(buf_entries, e)
          end
        end

        -- 2. Read current filesystem state — only recurse into loaded dirs
        local loaded_set = M._loaded_dirs[dir] or {}
        local disk_entries = fs.read_dir_loaded(dir, loaded_set)

        -- 3. Diff
        local ops = diff.compute_diff(buf_entries, disk_entries)

        -- 4. Validate — abort on errors
        if #ops.errors > 0 then
          apply.report_errors(buf, ops.errors)
          error("filebuf: validation failed")
        end

        -- Clear any stale diagnostics from a previous failed save
        vim.diagnostic.reset(nil, buf)

        -- 5. Apply
        apply.apply_ops(ops)

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

  M.config = vim.tbl_deep_extend("force", M.config, opts)

  -- Ensure highlight groups exist so users can override them in their
  -- colorscheme before the first buffer is opened.
  git.define_git_highlights()
  highlight.define_hidden_highlights()
  highlight.define_filebuf_highlights()

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
