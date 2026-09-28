SHELL := bash

PREK := uvx --from prek==$(shell bash scripts/tool-version.sh prek) prek
# The runner discovers NUL-delimited paths unless a caller explicitly overrides a list.
export PYTHON_FILES :=
export SHELL_FILES :=
export TEST_FILES :=
export ACTION_FILES :=

.PHONY: adoption-status check check-github-action-pins check-python check-shell check-tool-pins check-tool-updates outdated pre-commit pre-flight test

check: check-python check-shell check-tool-pins test

check-python:
	python3 -B scripts/run-make-check.py python '$(origin PYTHON_FILES)'

check-shell:
	python3 -B scripts/run-make-check.py shell '$(origin SHELL_FILES)'

check-tool-pins:
	python3 -B scripts/check-tool-pins.py

check-github-action-pins:
	python3 -B scripts/run-make-check.py action '$(origin ACTION_FILES)'

adoption-status:
	@test -n "$(strip $(CONSUMERS))" || { echo "Set CONSUMERS to explicit consumer paths" >&2; exit 2; }
	python3 -B scripts/report-adoption-status.py $(CONSUMERS)

check-tool-updates:
	bash scripts/check-tool-updates.bash

outdated: check-tool-updates

pre-commit:
	$(PREK) run --all-files

pre-flight: pre-commit

test:
	@python3 -B scripts/run-make-check.py test '$(origin TEST_FILES)'
