----------------------------------------------------------------------
-- Lightweight cumulative timer.  Enable with require("filebuf").profile(true).
-- start(name)/stop() bracket a scope; both no-op when disabled so the
-- instrumentation scattered through the scan/diff code stays cheap.
--
-- Nested sections: when an inner section starts, the outer section's
-- timer is *paused* and resumed when the inner stops.  This means:
--   • "self"  = exclusive time (no double-counting, sums to wall-clock)
--   • "incl"  = inclusive time (wall-clock duration, includes children)
--
-- Report: sections are grouped hierarchically by dot-separated name
-- prefixes (e.g. "scan.scan_into.find" nests under "scan.scan_into").
-- Parents show inclusive time; the grand total uses self time.
----------------------------------------------------------------------
local P = { enabled = false, _timers = {}, _stack = {} }

function P.start(name)
	if not P.enabled then
		return
	end
	local now = vim.loop.hrtime()
	-- Pause the currently-running section so its self time excludes the
	-- nested section we are about to start.
	local parent = P._stack[#P._stack]
	if parent then
		parent._self = parent._self + (now - parent._resumed_at)
	end
	P._stack[#P._stack + 1] = {
		name = name,
		_started_at = now,
		_resumed_at = now,
		_self = 0,
	}
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

	local now = vim.loop.hrtime()
	local self_ns = s._self + (now - s._resumed_at)
	local incl_ns = now - s._started_at

	local t = P._timers[s.name]
	if not t then
		t = { self_ns = 0, incl_ns = 0, count = 0, min_ns = math.huge, max_ns = 0 }
		P._timers[s.name] = t
	end
	t.self_ns = t.self_ns + self_ns
	t.incl_ns = t.incl_ns + incl_ns
	t.count = t.count + 1
	if self_ns < t.min_ns then
		t.min_ns = self_ns
	end
	if self_ns > t.max_ns then
		t.max_ns = self_ns
	end

	-- Resume parent so it starts accumulating again.
	local parent = P._stack[#P._stack]
	if parent then
		parent._resumed_at = now
	end
end

function P.set_enabled(enable)
	P.enabled = enable
	P._timers = {}
	P._stack = {}
	vim.notify("filebuf: profiling " .. (enable and "ON" or "OFF"), vim.log.levels.INFO)
end

--------------------------------------------------------------------------
-- Report: tree built from dot-separated name prefixes
--------------------------------------------------------------------------

--- Convert flat timing data into a tree keyed by dot-separated name.
--- An entry whose immediate prefix (drop last dot-component) matches
--- another entry becomes its child; otherwise it is a root.
local function build_tree(timers)
	-- Collect leaf data.
	local nodes = {}
	for name, t in pairs(timers) do
		nodes[name] = {
			name = name,
			self_ms = t.self_ns / 1e6,
			incl_ms = t.incl_ns / 1e6,
			count = t.count,
			min_ms = t.min_ns / 1e6,
			max_ms = t.max_ns / 1e6,
			children = {},
		}
	end

	local roots = {}
	for name, node in pairs(nodes) do
		local parent_name = name:match("^(.*)%.[^%.]+$")
		local parent = parent_name and nodes[parent_name]
		if parent then
			parent.children[#parent.children + 1] = node
		else
			roots[#roots + 1] = node
		end
	end

	return roots, nodes
end

--- Total self time of a node including all descendants.
local function subtree_self(node)
	local total = node.self_ms
	for _, child in ipairs(node.children) do
		total = total + subtree_self(child)
	end
	return total
end

--- Recursively sort: children by self_ms desc, roots by subtree self desc.
local function sort_tree(roots)
	for _, node in ipairs(roots) do
		sort_tree(node.children)
	end
	table.sort(roots, function(a, b)
		return subtree_self(a) > subtree_self(b)
	end)
	-- Within each parent, sort children by self time desc.
	for _, node in ipairs(roots) do
		table.sort(node.children, function(a, b)
			return a.self_ms > b.self_ms
		end)
	end
end

--- Print a per-scope timing report to :messages, grouped hierarchically.
---@return string[]  the printed lines
function P.report()
	local roots, _ = build_tree(P._timers)
	sort_tree(roots)

	-- Grand total = sum of all self times (equals wall-clock, no double-count).
	local grand_total = 0.0
	for _, t in pairs(P._timers) do
		grand_total = grand_total + t.self_ns / 1e6
	end

	local lines = { "=== filebuf profile ===" }

	-- Recursive printer.
	local function print_node(node, indent)
		local prefix = string.rep("  ", indent)
		local pct = grand_total > 0 and string.format("(%.0f%%)", node.self_ms / grand_total * 100) or ""

		-- Show inclusive time only when this section wraps children.
		local incl = ""
		if node.incl_ms - node.self_ms > 0.005 then
			incl = string.format("  incl %.2f ms", node.incl_ms)
		end

		local label = prefix .. node.name
		lines[#lines + 1] = string.format(
			"  %-42s %8.2f ms%s  x%-4d  %s  (min %.2f, max %.2f, avg %.2f)",
			label,
			node.self_ms,
			incl,
			node.count,
			pct,
			node.min_ms,
			node.max_ms,
			node.self_ms / node.count
		)

		for _, child in ipairs(node.children) do
			print_node(child, indent + 1)
		end
	end

	for _, root in ipairs(roots) do
		if #roots > 1 and root ~= roots[1] then
			lines[#lines + 1] = "" -- blank line between top-level groups
		end
		print_node(root, 0)
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = string.format("  %-42s %8.2f ms", "TOTAL (self)", grand_total)

	for _, line in ipairs(lines) do
		vim.api.nvim_echo({ { line .. "\n", "Normal" } }, true, {})
	end
	vim.notify("filebuf: profile report printed to :messages", vim.log.levels.INFO)
	return lines
end

return P
