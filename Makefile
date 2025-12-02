.PHONY: test

test:
	@nvim --headless --noplugin -u NONE -c "luafile tests/run_tests.lua" -c "qa!"
