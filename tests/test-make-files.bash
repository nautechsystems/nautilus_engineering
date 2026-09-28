#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The sourced file is linted separately; staged checks may omit it from their inputs
# shellcheck source=tests/make-environment.bash disable=SC1091
source "${SCRIPT_DIR}/make-environment.bash"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-make-files.XXXXXX")
trap 'rm -rf "$temp_root"' EXIT
mkdir "${temp_root}/physical"
ln -s "${temp_root}/physical" "${temp_root}/linked"
# Exercise a symlink and trailing slash in the fixture path on every platform
test_root="${temp_root}/linked/"
canonical_test_root=$(cd "$test_root" && pwd -P)
test_root="$canonical_test_root"
repo="${test_root}/repo with spaces"
mkdir -p "$repo" "${test_root}/bin"
cp "${REPO_ROOT}/Makefile" "${REPO_ROOT}/tools.toml" "$repo/"
cp -R "${REPO_ROOT}/scripts" "$repo/"
mkdir -p "${repo}/tests" "${repo}/.github/workflows"
git -C "$repo" init --quiet
printf 'value = 1\n' > "${repo}/module with space.py"
cat > "${repo}/tests/test-with space.bash" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
printf 'test ran\n' >> "$MARKER"
BASH
printf 'name: example\n' > "${repo}/.github/workflows/with space.yaml"
cat > "${repo}/scripts/check-github-action-shas.sh" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >> "$MARKER"
BASH
real_git=$(command -v git)
real_bash=$(command -v bash)
real_python=$(command -v python3)
cat > "${test_root}/bin/git" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1-}" == ls-files && "$FAIL_DISCOVERY" == 1 ]]; then
  if [[ "$FAIL_AFTER_OUTPUT" == 1 ]]; then
    "$REAL_GIT" "$@"
  fi
  echo 'Injected Make discovery failure' >&2
  exit 53
fi
exec "$REAL_GIT" "$@"
BASH
cat > "${test_root}/bin/bash" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1-}" == -n ]]; then
  printf '%s\n' "${@:2}" >> "$MARKER"
elif [[ "${1-}" == *tests/test-* ]]; then
  printf '%s\n' "$1" >> "$MARKER"
fi
exec "$REAL_BASH" "$@"
BASH
# An env-bash shebang would recurse through the fake bash itself.
printf '#!%s\n' "$real_bash" > "${test_root}/bin/bash-header"
tail -n +2 "${test_root}/bin/bash" >> "${test_root}/bin/bash-header"
mv "${test_root}/bin/bash-header" "${test_root}/bin/bash"
cat > "${test_root}/bin/python3" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1-}" == -m && "${2-}" == py_compile ]]; then
  printf '%s\n' "${@:3}" >> "$MARKER"
fi
exec "$REAL_PYTHON" "$@"
BASH
chmod +x "${test_root}/bin/git" "${test_root}/bin/bash" "${test_root}/bin/python3"
git -C "$repo" add -A
export REAL_GIT="$real_git" REAL_BASH="$real_bash" REAL_PYTHON="$real_python"
export PATH="${test_root}/bin:${PATH}" MARKER="${test_root}/ran"
export FAIL_DISCOVERY=0 FAIL_AFTER_OUTPUT=0
failures=0

expect_status() {
  local label=$1 expected=$2 status=0
  shift 2
  "$@" > "${test_root}/output" 2>&1 || status=$?
  if [[ "$status" != "$expected" ]]; then
    printf 'FAIL %s: expected %s, received %s\n' "$label" "$expected" "$status" >&2
    cat "${test_root}/output" >&2
    failures=$((failures + 1))
  else
    printf 'ok   %s\n' "$label"
  fi
}

for target in check-python check-shell test check-github-action-pins; do
  for after_output in 0 1; do
    : > "$MARKER"
    expect_status "$target rejects discovery failure (output=$after_output)" 2 \
      env FAIL_DISCOVERY=1 FAIL_AFTER_OUTPUT="$after_output" make --no-print-directory -C "$repo" "$target"
    if [[ -s "$MARKER" ]] || ! grep -Fx 'Injected Make discovery failure' "${test_root}/output" > /dev/null; then
      printf 'FAIL %s consumed failed discovery or missed the injection\n' "$target" >&2
      failures=$((failures + 1))
    fi
  done
  : > "$MARKER"
  expect_status "$target accepts discovered filenames with spaces" 0 \
    make --no-print-directory -C "$repo" "$target"
  case "$target" in
    check-python) expected_path="${repo}/module with space.py" ;;
    check-shell | test) expected_path="${repo}/tests/test-with space.bash" ;;
    check-github-action-pins) expected_path="${repo}/.github/workflows/with space.yaml" ;;
  esac
  if ! grep -Fx "$expected_path" "$MARKER" > /dev/null; then
    printf 'FAIL %s did not receive the intact filename\n' "$target" >&2
    failures=$((failures + 1))
  fi
done

expect_status 'explicit quoted selection preserves spaces' 0 \
  make --no-print-directory -C "$repo" test 'TEST_FILES="tests/test-with space.bash"'
expect_status 'empty explicit selection rejects' 2 \
  make --no-print-directory -C "$repo" test TEST_FILES=
expect_status 'malformed explicit selection rejects' 2 \
  make --no-print-directory -C "$repo" test 'TEST_FILES="unterminated'

cat > "${repo}/tests/test-second.bash" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
echo second >> "$MARKER"
BASH
: > "$MARKER"
expect_status 'explicit selection runs every requested file' 0 \
  make --no-print-directory -C "$repo" test \
  'TEST_FILES="tests/test-with space.bash" tests/test-second.bash'
if ! grep -Fx 'test ran' "$MARKER" > /dev/null || ! grep -Fx second "$MARKER" > /dev/null; then
  echo 'FAIL explicit selection did not run both tests' >&2
  failures=$((failures + 1))
fi

mkdir "${repo}/tests/test-group"
cat > "${repo}/tests/test-group/failure.bash" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
echo 'Injected nested companion failure' >&2
exit 48
BASH
expect_status 'test directories retain their nested companions' 2 \
  make --no-print-directory -C "$repo" test
if ! grep -Fx 'Injected nested companion failure' "${test_root}/output" > /dev/null; then
  echo 'FAIL nested companion was not executed' >&2
  failures=$((failures + 1))
fi

# Bash -n with several arguments checks only the first file: exercise a later one.
printf '#!/usr/bin/env bash\nif\n' > "${repo}/tests/zz-invalid.bash"
expect_status 'every discovered shell file is syntax checked' 2 \
  make --no-print-directory -C "$repo" check-shell

if ((failures > 0)); then
  printf '%s Make inventory tests failed\n' "$failures" >&2
  exit 1
fi
echo 'All Make inventory tests passed'
