----------------------------------------------------------------------
-- Preview — floating window showing file content with syntax highlighting.
-- Bound to K by default; delegates to vim.lsp.util.open_floating_preview
-- so focus-on-re-press, CursorMoved auto-close, and BufLeave cleanup
-- all work like native LSP hover.
----------------------------------------------------------------------
local M = {}

--- Active preview state.
local preview_win = nil ---@type number|nil
local preview_entry_path = nil ---@type string|nil

--- Shared focus_id so re-pressing K on the same entry focuses the window
--- instead of creating a new one.
local FOCUS_ID = "filebuf_preview"

--- Tear down the preview.  Safe to call even when nothing is open.
function M.close()
	if preview_win and vim.api.nvim_win_is_valid(preview_win) then
		pcall(vim.api.nvim_win_close, preview_win, true)
	end
	preview_win = nil
	preview_entry_path = nil
end

--- Detect whether a string is likely binary (contains null bytes or high
--- concentration of non-printable characters).
---@param lines string[]
---@return boolean
local function is_binary_content(lines)
	local total = 0
	local non_printable = 0
	for _, line in ipairs(lines) do
		total = total + #line
		for i = 1, #line do
			local b = line:byte(i)
			if b == 0 then
				return true
			end
			if b < 0x20 and b ~= 0x09 and b ~= 0x0A and b ~= 0x0D then
				non_printable = non_printable + 1
			end
		end
	end
	return total > 0 and (non_printable / total) > 0.1
end

--- Build preview content lines from a file on disk.
---@param path string
---@return string[]
local function build_content(path)
	local max_lines = 200

	if vim.fn.filereadable(path) ~= 1 then
		return { "(unreadable)" }
	end

	local lines = vim.fn.readfile(path, "", max_lines + 1)
	local truncated = #lines > max_lines
	if truncated then
		lines[#lines] = nil
	end

	if #lines == 0 then
		return { "(empty)" }
	end

	-- Binary check on the first screenful.
	local sample = {}
	for i = 1, math.min(#lines, 50) do
		sample[i] = lines[i]
	end
	if is_binary_content(sample) then
		return { "(binary file — preview not available)" }
	end

	if truncated then
		local stat = vim.loop.fs_stat(path)
		local size_hint = ""
		if stat and stat.size then
			local kb = math.floor(stat.size / 1024)
			size_hint = string.format(" (%d KB)", kb)
		end
		local notice = string.format("… showing first %d lines%s", max_lines, size_hint)
		table.insert(lines, 1, notice)
		table.insert(lines, 2, "")
	end

	return lines
end

--- Resolve filetype for an entry name.
---@param name string
---@return string
local function resolve_filetype(name)
	if vim.filetype and vim.filetype.match then
		local ft = vim.filetype.match({ filename = name })
		if ft and ft ~= "" then
			return ft
		end
	end
	local ext = name:match("%.([^.]+)$")
	if ext then
		local ft = vim.fn["getcompletion"](ext, "filetype")[1]
		if ft then
			return ft
		end
	end
	return "text"
end

--- Show a preview for `entry` in a floating window near the cursor.
--- If a preview is already open for the same entry, focus the window.
--- If a preview is already open for a different entry, close it and open a new one.
---@param _        number  the filebuf buffer (unused; kept for API consistency)
---@param entry    table   entry at cursor
function M.show(_, entry)
	if not entry or entry.type == "dir" then
		return
	end

	-- Different entry → close the old preview so a fresh one opens with new content.
	if preview_entry_path and preview_entry_path ~= entry.path then
		M.close()
	end

	local path = vim.loop.fs_realpath(entry.path) or entry.path
	local lines = build_content(path)
	local ft = resolve_filetype(entry.name)

	local bufnr, winid = vim.lsp.util.open_floating_preview(lines, ft, {
		border = "rounded",
		focus_id = FOCUS_ID,
		wrap = false,
		max_width = math.min(80, vim.o.columns - 8),
		max_height = math.min(vim.o.lines - 4, vim.o.lines - 8),
	})

	-- open_floating_preview doesn't set vim.bo.filetype directly; do it
	-- ourselves so syntax highlighting resolves through the standard path.
	if ft and ft ~= "" then
		vim.bo[bufnr].filetype = ft
	end

	preview_win = winid
	preview_entry_path = entry.path
end

return M
