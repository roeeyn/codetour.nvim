.PHONY: test fmt check hooks

test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"

fmt:
	stylua lua/ plugin/ tests/

check:
	stylua --check lua/ plugin/ tests/

# One-shot installer for the local pre-commit hook. Symlinks .github/pre-commit
# into .git/hooks/pre-commit so the script stays version-controlled. Run once
# after cloning; teammates who skip it still get caught by CI (when added).
hooks:
	@mkdir -p .git/hooks
	@chmod +x .github/pre-commit
	@ln -sf ../../.github/pre-commit .git/hooks/pre-commit
	@echo "pre-commit hook installed → .git/hooks/pre-commit"
