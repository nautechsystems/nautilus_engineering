#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-version-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
mkdir -p "${test_root}/.nautilus-engineering" "${test_root}/scripts"
cp \
  "${REPO_ROOT}/scripts/tool-version.sh" \
  "${REPO_ROOT}/scripts/cargo-tool-version.sh" \
  "${REPO_ROOT}/scripts/rust-toolchain.sh" \
  "${REPO_ROOT}/scripts/uv-version.sh" \
  "${test_root}/scripts/"

cat > "${test_root}/.nautilus-engineering/tools.toml" << 'TOML'
[uv]
version = "0.12.3"

[prek]
version = "nightly-2026-08-25"

[shellcheck]
version = "0.11.0.1"

[cargo-vet]
version = "0.10.1"
TOML
cat > "${test_root}/tools.toml" << 'TOML'
[actionlint]
version = "1.7.12"
TOML
cat > "${test_root}/Cargo.toml" << 'TOML'
[workspace]
members = []

[workspace.metadata.tools]
lychee = "0.21.0-beta.1"
TOML
cat > "${test_root}/rust-toolchain.toml" << 'TOML'
[toolchain]
channel = "1.91.0"
profile = "minimal"
TOML

failures=0

expect_output() {
  local label=$1 expected=$2
  shift 2
  local output status=0
  output=$("$@" 2>&1) || status=$?
  if [[ "$status" == 0 && "$output" == "$expected" ]]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s: exit %s, output %s\n' "$label" "$status" "$output" >&2
    failures=$((failures + 1))
  fi
}

expect_failure() {
  local label=$1 expected_status=$2 expected_text=$3
  shift 3
  local output status=0
  output=$("$@" 2>&1) || status=$?
  if [[ "$status" == "$expected_status" && "$output" == *"$expected_text"* ]]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s: exit %s\n%s\n' "$label" "$status" "$output" >&2
    failures=$((failures + 1))
  fi
}

expect_output "tool version reads semantic version" "0.12.3" \
  bash "${test_root}/scripts/tool-version.sh" uv
expect_output "tool version accepts pinned nightly" "nightly-2026-08-25" \
  bash "${test_root}/scripts/tool-version.sh" prek
expect_output "tool version accepts four-component version" "0.11.0.1" \
  bash "${test_root}/scripts/tool-version.sh" shellcheck
expect_output "tool version reads a consumer-local unique tool" "1.7.12" \
  bash "${test_root}/scripts/tool-version.sh" actionlint
expect_output "tool version recognizes an aliased local catalog path" "1.7.12" \
  env NAUTILUS_ENGINEERING_TOOLS_FILE="${test_root}/scripts/../tools.toml" \
  bash "${test_root}/scripts/tool-version.sh" actionlint
expect_output "uv version delegates to tool version" "0.12.3" \
  bash "${test_root}/scripts/uv-version.sh"
expect_failure "tool version requires one name" 2 "Usage: tool-version.sh" \
  bash "${test_root}/scripts/tool-version.sh"
expect_failure "tool version rejects unsafe name" 1 "Invalid tool name" \
  bash "${test_root}/scripts/tool-version.sh" '../uv'
expect_failure "tool version reports missing section" 1 "Could not find version" \
  bash "${test_root}/scripts/tool-version.sh" absent

expect_output "Cargo tool version reads stable version" "0.10.1" \
  bash "${test_root}/scripts/cargo-tool-version.sh" cargo-vet
expect_output "Cargo tool version accepts prerelease" "0.21.0-beta.1" \
  bash "${test_root}/scripts/cargo-tool-version.sh" lychee
expect_failure "Cargo tool version rejects unsafe name" 1 "Invalid cargo tool name" \
  bash "${test_root}/scripts/cargo-tool-version.sh" '../cargo-vet'
expect_failure "Cargo tool version reports missing entry" 1 "Could not find absent" \
  bash "${test_root}/scripts/cargo-tool-version.sh" absent

cat >> "${test_root}/tools.toml" << 'TOML'

[uv]
version = "0.12.2"
TOML
expect_failure "tool version rejects a shared and local duplicate" 1 "Duplicate tool version" \
  bash "${test_root}/scripts/tool-version.sh" uv

cat >> "${test_root}/Cargo.toml" << 'TOML'
cargo-vet = "0.10.0"
TOML
expect_failure "Cargo tool version rejects a shared and local duplicate" 1 \
  "Duplicate Cargo tool version" \
  bash "${test_root}/scripts/cargo-tool-version.sh" cargo-vet

expect_output "Rust toolchain reads exact channel" "1.91.0" \
  bash "${test_root}/scripts/rust-toolchain.sh"
cat > "${test_root}/rust-toolchain.toml" << 'TOML'
[toolchain]
channel = "stable"
TOML
expect_failure "Rust toolchain rejects moving channel" 1 "must be an exact Rust version" \
  bash "${test_root}/scripts/rust-toolchain.sh"

cat > "${test_root}/tools.toml" << 'TOML'
[uv]
version = "latest"
TOML
expect_failure "tool version rejects moving version" 1 "Invalid version for [uv]" \
  env NAUTILUS_ENGINEERING_TOOLS_FILE="${test_root}/tools.toml" \
  bash "${test_root}/scripts/tool-version.sh" uv
expect_failure "uv version preserves validation failure" 1 "Invalid version for [uv]" \
  env NAUTILUS_ENGINEERING_TOOLS_FILE="${test_root}/tools.toml" \
  bash "${test_root}/scripts/uv-version.sh"

if ((failures > 0)); then
  printf '\n%s version script test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nAll version script tests passed\n'
