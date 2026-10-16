#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-ci-install.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
test_root=$(cd "$test_root" && pwd -P)
fixture="$test_root/repo with spaces"
mkdir -p "$fixture/scripts/ci" "$test_root/bin" "$test_root/runner"
cp "$repo_root/scripts/ci/install-tools.bash" "$fixture/scripts/ci/"
cp "$repo_root/scripts/tool-version.sh" "$fixture/scripts/"
cat > "$fixture/tools.toml" << 'TOML'
[shellcheck]
version = "1.2.3"
[shfmt]
version = "2.3.4"
[prek]
version = "3.4.5"
[ruff]
version = "4.5.6"
[yamllint]
version = "5.6.7"
[taplo]
version = "6.7.8"
TOML
for tool in python go cargo; do
  cat > "$test_root/bin/$tool" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
tool=${0##*/}
printf '%s\0' "$tool" "$@" '' >> "$COMMAND_LOG"
case "$tool" in
  go) printf '%s' "$GOBIN" > "$INSTALL_CONTEXT" ;;
  cargo) printf '%s' "$CARGO_BUILD_JOBS" > "$INSTALL_CONTEXT" ;;
esac
if [[ "${FAIL_TOOL:-}" == "$tool" ]]; then
  exit 37
fi
BASH
  chmod +x "$test_root/bin/$tool"
done

export PATH="$test_root/bin:$PATH" RUNNER_TEMP="$test_root/runner"
export COMMAND_LOG="$test_root/commands" INSTALL_CONTEXT="$test_root/context"
unset NAUTILUS_ENGINEERING_TOOLS_FILE

run_install() {
  local expected_status=$1 status=0
  shift
  : > "$COMMAND_LOG"
  rm -f "$INSTALL_CONTEXT"
  bash "$fixture/scripts/ci/install-tools.bash" "$@" > "$test_root/output" 2>&1 || status=$?
  if [[ "$status" != "$expected_status" ]]; then
    cat "$test_root/output" >&2
    printf 'Expected install exit %s, found %s\n' "$expected_status" "$status" >&2
    exit 1
  fi
}

for mode in shell config; do
  if [[ "$mode" == shell ]]; then
    second_tool=go
    expected_context="$RUNNER_TEMP/bin"
  else
    second_tool=cargo
    expected_context=3
  fi
  CARGO_BUILD_JOBS=3 run_install 0 "$mode"
  python3 - "$COMMAND_LOG" "$mode" << 'PY'
from pathlib import Path
import sys

expected = (
    [["python", "-m", "pip", "install", "shellcheck-py==1.2.3"],
     ["go", "install", "mvdan.cc/sh/v3/cmd/shfmt@v2.3.4"]]
    if sys.argv[2] == "shell" else
    [["python", "-m", "pip", "install", "prek==3.4.5", "ruff==4.5.6", "yamllint==5.6.7"],
     ["cargo", "install", "taplo-cli", "--version", "6.7.8", "--locked"]]
)
actual = Path(sys.argv[1]).read_bytes()
assert actual == b"".join(b"\0".join(value.encode() for value in command) + b"\0\0"
                          for command in expected), actual
PY
  [[ $(cat "$INSTALL_CONTEXT") == "$expected_context" ]]
  cp "$COMMAND_LOG" "$test_root/expected"

  FAIL_TOOL=python run_install 37 "$mode"
  python3 - "$COMMAND_LOG" "$test_root/expected" << 'PY'
from pathlib import Path
import sys

actual = Path(sys.argv[1]).read_bytes()
expected = Path(sys.argv[2]).read_bytes().split(b"\0\0")[0] + b"\0\0"
assert actual == expected, actual
PY
  [[ ! -e "$INSTALL_CONTEXT" ]]

  CARGO_BUILD_JOBS=3 FAIL_TOOL="$second_tool" run_install 37 "$mode"
  cmp "$COMMAND_LOG" "$test_root/expected"
  printf 'ok   %s installation preserves pins and stops on command failure\n' "$mode"
done

unset CARGO_BUILD_JOBS
run_install 0 config
[[ $(cat "$INSTALL_CONTEXT") == 2 ]]

for mode in shell config; do
  cp "$fixture/tools.toml" "$test_root/catalog"
  sed 's/version = "2.3.4"/version = "latest"/; s/version = "6.7.8"/version = "latest"/' \
    "$test_root/catalog" > "$fixture/tools.toml"
  run_install 1 "$mode"
  [[ ! -s "$COMMAND_LOG" && ! -e "$INSTALL_CONTEXT" ]]
  cp "$test_root/catalog" "$fixture/tools.toml"
done

run_install 2
[[ ! -s "$COMMAND_LOG" ]]
run_install 2 unknown
[[ ! -s "$COMMAND_LOG" ]]
run_install 2 shell extra
[[ ! -s "$COMMAND_LOG" ]]
RUNNER_TEMP='' run_install 1 shell
[[ ! -s "$COMMAND_LOG" ]]
echo 'CI tool installation tests passed'
