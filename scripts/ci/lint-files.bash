#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 || ! "$1" =~ ^(shell|python|markdown|toml)$ ]]; then
  echo 'Usage: lint-files.bash {shell|python|markdown|toml}' >&2
  exit 2
fi
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
cd "$repo_root"

if [[ "$1" == toml ]]; then
  files=(config/rustfmt.toml config/taplo.toml pyproject.toml sync/manifest.toml tools.toml)
else
  file_list=$(mktemp "${TMPDIR:-/tmp}/nautilus-ci-files.XXXXXX")
  trap 'rm -f "$file_list"' EXIT
  python3 -B scripts/run-make-check.py --list "$1" file > "$file_list"
  files=()
  while IFS= read -r -d '' path; do
    files+=("$path")
  done < "$file_list"
fi

case "$1" in
  shell)
    : "${RUNNER_TEMP:?RUNNER_TEMP is required for the shfmt executable}"
    shellcheck "${files[@]}"
    "${RUNNER_TEMP}/bin/shfmt" -d -i 2 -ci -sr -ln bash "${files[@]}"
    ;;
  python)
    ruff check "${files[@]}"
    ruff format --check "${files[@]}"
    ;;
  markdown)
    markdownlint_version=$(bash scripts/tool-version.sh markdownlint-cli2)
    npx --yes "markdownlint-cli2@$markdownlint_version" \
      --config config/markdownlint.jsonc "${files[@]}"
    python3 -B scripts/check-markdown-tables.py "${files[@]}"
    ;;
  toml)
    taplo format --check --config config/taplo.toml "${files[@]}"
    taplo lint --config config/taplo.toml "${files[@]}"
    ;;
esac
