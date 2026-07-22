----------------------------------------------------------------------
-- Unit tests for line.lua — entry ↔ buffer-text formatting.
-- Tests pure functions: format_line, parse_line, indent_level, indent_str.
----------------------------------------------------------------------
local line = require("filebuf.line")

describe("line.lua", function()
	before_each(function()
		-- Consistent indent settings for predictable tests.
		vim.go.expandtab = true
		vim.go.shiftwidth = 2
	end)

	------------------------------------------------------------------
	-- format_line
	------------------------------------------------------------------
	describe("format_line", function()
		it("formats a dir entry with trailing / and indent", function()
			local entry = { name = "mydir", type = "dir", indent = 1 }
			local result = line.format_line(entry)
			-- shiftwidth=2, indent=1 → 2 spaces, then "mydir/"
			assert.equals("  mydir/", result)
		end)

		it("formats a file entry with no suffix", function()
			local entry = { name = "myfile", type = "file", indent = 0 }
			local result = line.format_line(entry)
			assert.equals("myfile", result)
		end)

		it("formats a link entry with trailing @", function()
			local entry = { name = "mylink", type = "link", indent = 2 }
			local result = line.format_line(entry)
			-- shiftwidth=2, indent=2 → 4 spaces, then "mylink@"
			assert.equals("    mylink@", result)
		end)

		it("formats a root-level entry with no indent", function()
			local entry = { name = "rootfile", type = "file", indent = 0 }
			local result = line.format_line(entry)
			assert.equals("rootfile", result)
		end)

		it("formats a deeply-indented entry", function()
			local entry = { name = "deep", type = "dir", indent = 3 }
			local result = line.format_line(entry)
			assert.equals("      deep/", result) -- 6 spaces
		end)

		it("escapes newline in names as $'\\n'", function()
			local entry = { name = "a\nb", type = "file", indent = 0 }
			local result = line.format_line(entry)
			assert.equals("a$'\\n'b", result)
		end)

		it("escapes return in names as $'\\r'", function()
			local entry = { name = "a\rb", type = "file", indent = 0 }
			local result = line.format_line(entry)
			assert.equals("a$'\\r'b", result)
		end)

		it("escapes tab in names as $'\\t'", function()
			local entry = { name = "a\tb", type = "file", indent = 0 }
			local result = line.format_line(entry)
			assert.equals("a$'\\t'b", result)
		end)
	end)

	------------------------------------------------------------------
	-- parse_line
	------------------------------------------------------------------
	describe("parse_line", function()
		it("parses a dir line → name, is_dir=true, is_link=false", function()
			local name, is_dir, is_link = line.parse_line("  mydir/")
			assert.equals("mydir", name)
			assert.is_true(is_dir)
			assert.is_false(is_link)
		end)

		it("parses a file line → name, is_dir=false, is_link=false", function()
			local name, is_dir, is_link = line.parse_line("  myfile")
			assert.equals("myfile", name)
			assert.is_false(is_dir)
			assert.is_false(is_link)
		end)

		it("parses a link line → name, is_dir=false, is_link=true", function()
			local name, is_dir, is_link = line.parse_line("  mylink@")
			assert.equals("mylink", name)
			assert.is_false(is_dir)
			assert.is_true(is_link)
		end)

		it("strips leading whitespace from name", function()
			local name, _, _ = line.parse_line("    spacedir/")
			assert.equals("spacedir", name)
		end)

		it("does not confuse @ suffix with dir / suffix", function()
			-- A line ending with "/" is a dir, not a link, even though it contains @.
			local name, is_dir, is_link = line.parse_line("my@dir/")
			assert.equals("my@dir", name)
			assert.is_true(is_dir)
			assert.is_false(is_link)
		end)

		it("unescapes $'\\n' back to newline", function()
			local name, _, _ = line.parse_line("a$'\\n'b")
			assert.equals("a\nb", name)
		end)

		it("unescapes $'\\r' back to carriage return", function()
			local name, _, _ = line.parse_line("a$'\\r'b")
			assert.equals("a\rb", name)
		end)

		it("unescapes $'\\t' back to tab", function()
			local name, _, _ = line.parse_line("a$'\\t'b")
			assert.equals("a\tb", name)
		end)
	end)

	------------------------------------------------------------------
	-- Round-trip
	------------------------------------------------------------------
	describe("round-trip", function()
		it("parse_line(format_line(entry)) preserves name and type for dir", function()
			local entry = { name = "testdir", type = "dir", indent = 1 }
			local formatted = line.format_line(entry)
			local name, is_dir, is_link = line.parse_line(formatted)
			assert.equals("testdir", name)
			assert.is_true(is_dir)
			assert.is_false(is_link)
		end)

		it("parse_line(format_line(entry)) preserves name and type for file", function()
			local entry = { name = "testfile", type = "file", indent = 2 }
			local formatted = line.format_line(entry)
			local name, is_dir, is_link = line.parse_line(formatted)
			assert.equals("testfile", name)
			assert.is_false(is_dir)
			assert.is_false(is_link)
		end)

		it("parse_line(format_line(entry)) preserves name and type for link", function()
			local entry = { name = "testlink", type = "link", indent = 0 }
			local formatted = line.format_line(entry)
			local name, is_dir, is_link = line.parse_line(formatted)
			assert.equals("testlink", name)
			assert.is_false(is_dir)
			assert.is_true(is_link)
		end)

		it("round-trips names with special characters", function()
			local entry = { name = "file\nwith\ttabs\r", type = "file", indent = 0 }
			local formatted = line.format_line(entry)
			local name, is_dir, is_link = line.parse_line(formatted)
			assert.equals("file\nwith\ttabs\r", name)
			assert.is_false(is_dir)
			assert.is_false(is_link)
		end)
	end)

	------------------------------------------------------------------
	-- indent_level
	------------------------------------------------------------------
	describe("indent_level", function()
		it("returns 0 for a line with no leading whitespace", function()
			assert.equals(0, line.indent_level("myfile"))
		end)

		it("returns 1 for a line with one indent level of spaces", function()
			assert.equals(1, line.indent_level("  myfile")) -- 2 spaces
		end)

		it("returns 2 for a line with two indent levels of spaces", function()
			assert.equals(2, line.indent_level("    myfile")) -- 4 spaces
		end)

		it("handles empty or whitespace-only lines", function()
			-- Empty string has 0 whitespace → indent 0.
			assert.equals(0, line.indent_level(""))
			-- Whitespace-only: 3 spaces / shiftwidth 2 = 1 indent level.
			assert.equals(1, line.indent_level("   "))
		end)
	end)

	------------------------------------------------------------------
	-- indent_width
	------------------------------------------------------------------
	describe("indent_width", function()
		it("returns shiftwidth when greater than 0", function()
			vim.go.shiftwidth = 4
			assert.equals(4, line.indent_width())
		end)

		it("falls back to tabstop when shiftwidth is 0", function()
			vim.go.shiftwidth = 0
			vim.go.tabstop = 8
			assert.equals(8, line.indent_width())
			-- Restore for other tests.
			vim.go.shiftwidth = 2
		end)
	end)

	------------------------------------------------------------------
	-- indent_str
	------------------------------------------------------------------
	describe("indent_str", function()
		it("returns empty string for level 0", function()
			assert.equals("", line.indent_str(0))
		end)

		it("returns empty string for negative level", function()
			assert.equals("", line.indent_str(-1))
		end)

		it("returns 2 spaces for level 1 with shiftwidth=2", function()
			assert.equals("  ", line.indent_str(1))
		end)

		it("returns 4 spaces for level 2 with shiftwidth=2", function()
			assert.equals("    ", line.indent_str(2))
		end)
	end)
end)
