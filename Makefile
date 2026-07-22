.PHONY: test test-unit test-integration

# Run all tests.
test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "lua require('plenary.test_harness').test_directory('tests/', { minimal_init = 'tests/minimal_init.lua', sequential = true })"

# Run only unit tests (pure logic, fast).
test-unit:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "lua require('plenary.test_harness').test_directory('tests/unit/', { minimal_init = 'tests/minimal_init.lua', sequential = true })"

# Run only integration tests (filesystem I/O, headless Neovim).
test-integration:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "lua require('plenary.test_harness').test_directory('tests/integration/', { minimal_init = 'tests/minimal_init.lua', sequential = true })"
