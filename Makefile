# Default tools; override like: make NVIM=/opt/homebrew/bin/nvim
NVIM     ?= nvim
EMMYLUA  ?= $(shell which emmylua_check 2>/dev/null || echo "$(HOME)/.local/share/nvim/mason/bin/emmylua_check")
SELENE   ?= $(shell which selene 2>/dev/null || echo "$(HOME)/.local/share/nvim/mason/bin/selene")
STYLUA   ?= $(shell which stylua 2>/dev/null || echo "$(HOME)/.local/share/nvim/mason/bin/stylua")

PROJECT ?= lua/ tests/

.PHONY: emmylua luals selene selene-file format-check format format-file check test validate install-hooks

test:
	$(NVIM) --headless -u tests/init.lua -c "lua require('tests.runner').run()"

test-verbose:
	$(NVIM) --headless -u tests/init.lua -c "lua require('tests.runner').run({verbose = true})"

test-file:
	$(NVIM) --headless -u tests/init.lua -c "lua require('tests.runner').run_file('$(FILE)')"

# EmmyLua headless diagnosis report
emmylua:
	@VIMRUNTIME=$$($(NVIM) --headless -c 'echo $$VIMRUNTIME' -c q 2>&1); \
	if [ -z "$$VIMRUNTIME" ]; then \
		echo "Error: Could not determine VIMRUNTIME. Check that '$(NVIM)' is on PATH and runnable" >&2; \
		exit 1; \
	fi; \
	for dir in $(PROJECT); do \
		echo "Checking $$dir..."; \
		VIMRUNTIME="$$VIMRUNTIME" "$(EMMYLUA)" "$$dir" --config "$(CURDIR)/.luarc.json" --warnings-as-errors || exit 1; \
	done

# Backward-compatible alias
luals: emmylua

# Selene linter
selene:
	"$(SELENE)" .

# Selene a specific file
selene-file:
	"$(SELENE)" "$(FILE)"

# StyLua formatting check
format-check:
	"$(STYLUA)" --check .

# StyLua formatting (apply)
format:
	"$(STYLUA)" .

# Format a specific file
format-file:
	"$(STYLUA)" "$(FILE)"

# Convenience aggregator, NOT to be used in the CI
check: format-check emmylua selene

# Run all validations with output redirection for AI agents
validate:
	@mkdir -p .local; \
	total_start=$$(date +%s); \
	failed_steps=""; \
	append_failed_step() { \
		if [ -z "$$failed_steps" ]; then \
			failed_steps="$$1"; \
		else \
			failed_steps="$$failed_steps, $$1"; \
		fi; \
	}; \
	start=$$(date +%s); \
	$(MAKE) format > .local/agentic_format_output.log 2>&1; \
	rc_format=$$?; \
	if [ $$rc_format -ne 0 ]; then append_failed_step format; fi; \
	echo "format: $$rc_format (took $$(($$(date +%s) - start))s) - log: .local/agentic_format_output.log"; \
	start=$$(date +%s); \
	$(MAKE) emmylua > .local/agentic_emmylua_output.log 2>&1; \
	rc_emmylua=$$?; \
	if [ $$rc_emmylua -ne 0 ]; then append_failed_step emmylua; fi; \
	echo "emmylua: $$rc_emmylua (took $$(($$(date +%s) - start))s) - log: .local/agentic_emmylua_output.log"; \
	start=$$(date +%s); \
	$(MAKE) selene > .local/agentic_selene_output.log 2>&1; \
	rc_selene=$$?; \
	if [ $$rc_selene -ne 0 ]; then append_failed_step selene; fi; \
	echo "selene: $$rc_selene (took $$(($$(date +%s) - start))s) - log: .local/agentic_selene_output.log"; \
	start=$$(date +%s); \
	$(MAKE) test > .local/agentic_test_output.log 2>&1; \
	rc_test=$$?; \
	if [ $$rc_test -ne 0 ]; then append_failed_step test; fi; \
	echo "test: $$rc_test (took $$(($$(date +%s) - start))s) - log: .local/agentic_test_output.log"; \
	echo "Total: $$(($$(date +%s) - total_start))s"; \
	if [ -n "$$failed_steps" ]; then \
		echo "Validation failed: $$failed_steps. Check log files for details."; \
		exit 1; \
	fi

# Install pre-commit hook locally
install-git-hooks:
	@mkdir -p .git/hooks
	@printf '%s\n' \
		'#!/bin/sh' \
		'set -e' \
		'STYLUA=$$(which stylua 2>/dev/null || echo "$$HOME/.local/share/nvim/mason/bin/stylua")' \
		'STAGED_LUA_FILES=$$(git diff --cached --name-only --diff-filter=ACM | grep "\.lua$$" || true)' \
		'if [ -n "$$STAGED_LUA_FILES" ]; then' \
		'  echo "Running stylua on staged files..."' \
		'  "$$STYLUA" $$STAGED_LUA_FILES' \
		'  git add $$STAGED_LUA_FILES' \
		'fi' \
		> .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "Pre-commit hook installed successfully"