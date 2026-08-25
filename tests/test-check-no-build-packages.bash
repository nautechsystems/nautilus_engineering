#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_SCRIPT="${REPO_ROOT}/scripts/check-no-build-packages.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-no-build-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
repo="${test_root}/repo"
mkdir -p "${repo}/nested" "${repo}/scripts"
cp "$SOURCE_SCRIPT" "${repo}/scripts/check-no-build-packages.sh"
CHECK_SCRIPT="${repo}/scripts/check-no-build-packages.sh"
git -C "$repo" init --quiet

write_root_lock() {
  cat > "${repo}/uv.lock" << 'LOCK'
version = 1

[[package]]
name = "alpha"
version = "1.2.3"
source = { registry = "https://pypi.org/simple" }

[[package]]
name = "bravo"
version = "4.5.6"
source = { git = "https://example.com/bravo.git" }

[[package]]
name = "workspace-project"
version = "0.1.0"
source = { editable = "." }
LOCK
}

write_root_manifest() {
  local body=$1
  cat > "${repo}/pyproject.toml" << TOML
[project]
name = "workspace-project"
version = "0.1.0"

[tool.uv]
no-build-package = [
${body}
]
TOML
}

write_root_lock
write_root_manifest '  "alpha",
  "bravo",'
cat > "${repo}/nested/uv.lock" << 'LOCK'
version = 1

[[package]]
name = "charlie"
version = "7.8.9"
source = { url = "https://example.com/charlie.whl" }

[[package]]
name = "nested-project"
version = "0.2.0"
source = { directory = "." }
LOCK
cat > "${repo}/nested/pyproject.toml" << 'TOML'
[project]
name = "nested-project"
version = "0.2.0"

[tool.uv]
no-build-package = [
  "charlie",
]
TOML
git -C "$repo" add -A

failures=0

expect() {
  local label=$1 expected_status=$2 expected_text=$3
  shift 3
  local output status=0
  output=$(cd "$repo" && bash "$CHECK_SCRIPT" "$@" 2>&1) || status=$?
  if [[ "$status" == "$expected_status" && "$output" == *"$expected_text"* ]]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s: exit %s\n%s\n' "$label" "$status" "$output" >&2
    failures=$((failures + 1))
  fi
}

expect "auto-discovery checks every eligible tracked lock" 0 \
  "nested/pyproject.toml: 1 packages"

write_root_manifest '  "alpha",'
expect "missing package fails" 1 "Missing from no-build-package (1)"

write_root_manifest '  "alpha",
  "bravo",
  "stale",'
expect "stale package fails" 1 "Listed in no-build-package but not in lock (1)"

write_root_manifest '  "alpha",
  "alpha",
  "bravo",'
expect "duplicate package fails" 1 "Duplicate entries: alpha"

write_root_manifest '  "bravo",
  "alpha",'
expect "out-of-order package fails" 1 "Entries are not sorted alphabetically"

write_root_manifest '  "alpha",
  "bravo",'
real_comm=$(command -v comm)
fake_bin="${test_root}/bin"
mkdir "$fake_bin"
cat > "${fake_bin}/comm" << 'BASH'
#!/usr/bin/env bash
if [[ "${LC_ALL:-}" != C ]]; then
  echo "comm did not receive LC_ALL=C" >&2
  exit 9
fi
exec "$REAL_COMM" "$@"
BASH
chmod +x "${fake_bin}/comm"
REAL_COMM="$real_comm" PATH="${fake_bin}:${PATH}" expect \
  "comm uses the C locale used for sorting" 0 \
  "pyproject.toml: 2 packages"

mkdir -p "${repo}/explicit"
cp "${repo}/nested/uv.lock" "${repo}/explicit/uv.lock"
cp "${repo}/nested/pyproject.toml" "${repo}/explicit/pyproject.toml"
expect "explicit untracked pair is checked" 0 "explicit/pyproject.toml: 1 packages" \
  --pair explicit/uv.lock:explicit/pyproject.toml
expect "unsafe explicit path is rejected" 2 "missing ../uv.lock" \
  --pair ../uv.lock:pyproject.toml
expect "malformed pair is rejected" 2 "pair must be LOCK:MANIFEST" \
  --pair uv.lock

empty_repo="${test_root}/empty"
mkdir -p "${empty_repo}/scripts"
cp "$SOURCE_SCRIPT" "${empty_repo}/scripts/check-no-build-packages.sh"
git -C "$empty_repo" init --quiet
printf '[project]\nname = "empty"\nversion = "0.1.0"\n' > "${empty_repo}/pyproject.toml"
git -C "$empty_repo" add pyproject.toml
status=0
output=$(cd "$empty_repo" && bash scripts/check-no-build-packages.sh 2>&1) || status=$?
if [[ "$status" == 0 && "$output" == "No tracked uv.lock has a no-build-package policy." ]]; then
  printf 'ok   repository without policy is a clean no-op\n'
else
  printf 'FAIL no-policy repository: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

if ((failures > 0)); then
  printf '\n%s no-build-package test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nAll no-build-package tests passed\n'
