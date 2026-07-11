# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

**filebuf** is a Neovim Lua plugin that renders a recursive, indent-based directory tree as an editable buffer. Users can create, rename, and delete filesystem entries by editing the buffer lines inline.

## Commands

There is no build step, test suite, or linter configured. The plugin is a single Lua file consumed directly by Neovim via `lazy.nvim`:

```lua
{ "user/filebuf", dir = "~/path/to/filebuf", config = true }
```

To exercise changes manually, open Neovim and run `:Filebuf` or `:lua require("filebuf").open()`.

## Architecture

### No external dependencies

The plugin uses only built-in Neovim APIs (`vim.fn`, `vim.loop`, `vim.api`). It has no luarocks or other Lua module dependencies.
