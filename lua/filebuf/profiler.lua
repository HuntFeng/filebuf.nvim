----------------------------------------------------------------------
-- Lightweight cumulative timer.  Enable with require("filebuf").profile(true).
-- start(name)/stop() bracket a scope; both no-op when disabled so the
-- instrumentation scattered through the scan/diff code stays cheap.
----------------------------------------------------------------------
local P = { enabled = false, _timers = {}, _stack = {} }

function P.start(name)
	if not P.enabled then
		return
	end
	P._stack[#P._stack + 1] = { name = name, t = vim.loop.hrtime() }
end

function P.stop()
	if not P.enabled then
		return
	end
	local s = P._stack[#P._stack]
	if not s then
		return
	end
	P._stack[#P._stack] = nil
	local elapsed = (vim.loop.hrtime() - s.t) / 1e6 -- ms
	local t = P._timers[s.name]
	if not t then
		t = { total = 0, count = 0, min = math.huge, max = 0 }
		P._timers[s.name] = t
	end
	t.total = t.total + elapsed
	t.count = t.count + 1
	t.min = math.min(t.min, elapsed)
	t.max = math.max(t.max, elapsed)
end

function P.set_enabled(enable)
	P.enabled = enable
	P._timers = {}
	P._stack = {}
	vim.notify("filebuf: profiling " .. (enable and "ON" or "OFF"), vim.log.levels.INFO)
end

--- Print a per-scope timing report to :messages, sorted by total time.
---@return string[]  the printed lines
function P.report()
	local sorted = {}
	for name, t in pairs(P._timers) do
		sorted[#sorted + 1] =
			{ name = name, total = t.total, count = t.count, min = t.min, max = t.max, avg = t.total / t.count }
	end
	table.sort(sorted, function(a, b)
		return a.total > b.total
	end)

	local grand_total = 0
	for _, s in ipairs(sorted) do
		grand_total = grand_total + s.total
	end

	local lines = { "=== filebuf profile ===" }
	for _, s in ipairs(sorted) do
		local pct = grand_total > 0 and string.format("(%.0f%%)", s.total / grand_total * 100) or ""
		lines[#lines + 1] = string.format(
			"  %-35s %8.2f ms  x%-4d  %s  (min %.2f, max %.2f, avg %.2f)",
			s.name,
			s.total,
			s.count,
			pct,
			s.min,
			s.max,
			s.avg
		)
	end
	lines[#lines + 1] = string.format("  %-35s %8.2f ms", "TOTAL", grand_total)

	for _, line in ipairs(lines) do
		vim.api.nvim_echo({ { line .. "\n", "Normal" } }, true, {})
	end
	vim.notify("filebuf: profile report printed to :messages", vim.log.levels.INFO)
	return lines
end

return P
