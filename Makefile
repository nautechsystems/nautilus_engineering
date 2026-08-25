SHELL := bash

PYTHON_FILES := $(shell git ls-files --cached --others --exclude-standard -- '*.py' | LC_ALL=C sort)
SHELL_FILES := $(shell git ls-files --cached --others --exclude-standard -- scripts sync tests | awk '/\.(bash|sh)$$/' | LC_ALL=C sort)
TEST_FILES := $(shell git ls-files --cached --others --exclude-standard -- tests | awk '/\/test-.*\.bash$$/' | LC_ALL=C sort)
ACTION_FILES := $(shell git ls-files --cached --others --exclude-standard -- .github | awk '/\.(yaml|yml)$$/' | LC_ALL=C sort)

.PHONY: check check-github-action-pins check-python check-shell test

check: check-python check-shell test

check-python:
	@test -n "$(strip $(PYTHON_FILES))" || { echo "No tracked Python files found" >&2; exit 1; }
	python3 -m py_compile $(PYTHON_FILES)

check-shell:
	@test -n "$(strip $(SHELL_FILES))" || { echo "No tracked shell files found" >&2; exit 1; }
	bash -n $(SHELL_FILES)

check-github-action-pins:
	@test -n "$(strip $(ACTION_FILES))" || { echo "No tracked GitHub Action files found" >&2; exit 1; }
	bash scripts/check-github-action-shas.sh $(ACTION_FILES)

test:
	@test -n "$(strip $(TEST_FILES))" || { echo "No tracked test files found" >&2; exit 1; }
	@set -e; for test_file in $(TEST_FILES); do \
		printf '\n%s\n' "Running $$test_file"; \
		bash "$$test_file"; \
	done
