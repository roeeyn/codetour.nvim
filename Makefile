.PHONY: test fmt check

test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"

fmt:
	stylua lua/ plugin/ tests/

check:
	stylua --check lua/ plugin/ tests/
