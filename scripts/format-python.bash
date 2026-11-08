#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ruff_version=$(bash "$repo_root/scripts/tool-version.sh" ruff)
exec uvx --python ">=3.12" --from "ruff==$ruff_version" python -B "$repo_root/scripts/format-python.py" "$@"
