#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-ci-lint.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
test_root=$(cd "$test_root" && pwd -P)
fixture="$test_root/repo with spaces"
mkdir -p "$fixture/scripts/ci" "$fixture/config" "$fixture/sync" "$fixture/tests" \
  "$test_root/bin" "$test_root/runner/bin" "$test_root/temp"
cp "$repo_root/scripts/ci/lint-files.bash" "$fixture/scripts/ci/"
cp "$repo_root/scripts/run-make-check.py" "$repo_root/scripts/tool-version.sh" "$fixture/scripts/"
printf '[markdownlint-cli2]\nversion = "7.8.9"\n' > "$fixture/tools.toml"
printf 'value = 23\n' > "$fixture/module with space.py"
printf '# Example\n' > "$fixture/readme with space.md"
printf '#!/usr/bin/env bash\n' > "$fixture/scripts/script with space.bash"
printf '#!/usr/bin/env bash\n' > "$fixture/sync/sample.sh"
printf '#!/usr/bin/env bash\n' > "$fixture/tests/test-example.bash"
touch "$fixture/config/rustfmt.toml" "$fixture/config/taplo.toml" \
  "$fixture/pyproject.toml" "$fixture/sync/manifest.toml" "$fixture/scripts/check-markdown-tables.py"
git -C "$fixture" init --quiet
real_git=$(command -v git)
real_python=$(command -v python3)

cat > "$test_root/bin/git" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == ls-files ]]; then
  if [[ "${EMPTY_DISCOVERY:-0}" == 1 ]]; then
    exit 0
  fi
  if [[ "${FAIL_DISCOVERY:-0}" == 1 ]]; then
    "$REAL_GIT" "$@"
    exit 53
  fi
fi
exec "$REAL_GIT" "$@"
BASH
chmod +x "$test_root/bin/git"
for tool in shellcheck ruff npx taplo python3; do
  cat > "$test_root/bin/$tool" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
tool=${0##*/}
if [[ "$tool" == python3 && "${2:-}" != scripts/check-markdown-tables.py ]]; then
  exec "$REAL_PYTHON" "$@"
fi
printf '%s\0' "$tool" "$@" '' >> "$COMMAND_LOG"
if [[ "${FAIL_TOOL:-}" == "$tool" && ( -z "${FAIL_ARGUMENT:-}" || "${1:-}" == "$FAIL_ARGUMENT" ) ]]; then
  exit 37
fi
BASH
  chmod +x "$test_root/bin/$tool"
done
cp "$test_root/bin/shellcheck" "$test_root/runner/bin/shfmt"

export PATH="$test_root/bin:$PATH" REAL_GIT="$real_git" REAL_PYTHON="$real_python"
export COMMAND_LOG="$test_root/commands" RUNNER_TEMP="$test_root/runner" TMPDIR="$test_root/temp"
unset NAUTILUS_ENGINEERING_TOOLS_FILE

run_lint() {
  local expected_status=$1 status=0
  shift
  : > "$COMMAND_LOG"
  bash "$fixture/scripts/ci/lint-files.bash" "$@" > "$test_root/output" 2>&1 || status=$?
  if [[ "$status" != "$expected_status" ]]; then
    cat "$test_root/output" >&2
    printf 'Expected lint exit %s, found %s\n' "$expected_status" "$status" >&2
    exit 1
  fi
  [[ -z $(ls -A "$TMPDIR") ]]
}

for mode in shell python markdown toml; do
  run_lint 0 "$mode"
  "$real_python" - "$COMMAND_LOG" "$fixture" "$mode" << 'PY'
from pathlib import Path
import sys

root = Path(sys.argv[2])
mode = sys.argv[3]
paths = {
    "shell": ["scripts/ci/lint-files.bash", "scripts/script with space.bash",
              "scripts/tool-version.sh", "sync/sample.sh", "tests/test-example.bash"],
    "python": ["module with space.py", "scripts/check-markdown-tables.py", "scripts/run-make-check.py"],
    "markdown": ["readme with space.md"],
    "toml": ["config/rustfmt.toml", "config/taplo.toml", "pyproject.toml",
             "sync/manifest.toml", "tools.toml"],
}[mode]
files = paths if mode == "toml" else [str(root / path) for path in sorted(paths)]
commands = {
    "shell": [["shellcheck", *files], ["shfmt", "-d", "-i", "2", "-ci", "-sr", "-ln", "bash", *files]],
    "python": [["ruff", "check", *files], ["ruff", "format", "--check", *files]],
    "markdown": [["npx", "--yes", "markdownlint-cli2@7.8.9", "--config", "config/markdownlint.jsonc", *files],
                 ["python3", "-B", "scripts/check-markdown-tables.py", *files]],
    "toml": [["taplo", "format", "--check", "--config", "config/taplo.toml", *files],
             ["taplo", "lint", "--config", "config/taplo.toml", *files]],
}[mode]
expected = b"".join(b"\0".join(value.encode() for value in command) + b"\0\0" for command in commands)
actual = Path(sys.argv[1]).read_bytes()
assert actual == expected, (actual, expected)
PY
  cp "$COMMAND_LOG" "$test_root/expected"
  case "$mode" in
    shell)
      first_tool=shellcheck
      second_tool=shfmt
      second_argument=-d
      ;;
    python)
      first_tool=ruff
      second_tool=ruff
      second_argument=format
      ;;
    markdown)
      first_tool=npx
      second_tool=python3
      second_argument=-B
      ;;
    toml)
      first_tool=taplo
      second_tool=taplo
      second_argument=lint
      ;;
  esac
  FAIL_TOOL="$first_tool" run_lint 37 "$mode"
  "$real_python" - "$COMMAND_LOG" "$test_root/expected" << 'PY'
from pathlib import Path
import sys

actual = Path(sys.argv[1]).read_bytes()
expected = Path(sys.argv[2]).read_bytes().split(b"\0\0")[0] + b"\0\0"
assert actual == expected, actual
PY
  FAIL_TOOL="$second_tool" FAIL_ARGUMENT="$second_argument" run_lint 37 "$mode"
  cmp "$COMMAND_LOG" "$test_root/expected"
  if [[ "$mode" != toml ]]; then
    FAIL_DISCOVERY=1 run_lint 53 "$mode"
    [[ ! -s "$COMMAND_LOG" ]]
    EMPTY_DISCOVERY=1 run_lint 2 "$mode"
    [[ ! -s "$COMMAND_LOG" ]]
  fi
  printf 'ok   %s lint preserves filenames and propagates failures\n' "$mode"
done

run_lint 2
run_lint 2 unknown
run_lint 2 python extra
[[ ! -s "$COMMAND_LOG" ]]
RUNNER_TEMP='' run_lint 1 shell
[[ ! -s "$COMMAND_LOG" ]]
echo 'CI lint tests passed'
