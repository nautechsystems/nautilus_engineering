#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-tool-pins-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

mkdir -p "${test_root}/.github/workflows" "${test_root}/pre-commit" "${test_root}/scripts"
cp "${REPO_ROOT}/scripts/check-tool-pins.py" "${test_root}/scripts/"
cp "${REPO_ROOT}/scripts/tool-version.sh" "${test_root}/scripts/"

write_catalog() {
  local cargo_audit_version=$1

  cat > "${test_root}/tools.toml" << TOML
[alpha]
version = "1.2.3"
ci = true
pre-commit-repository = "https://example.com/alpha"
pre-commit-revision = "v{version}"
pre-commit-fragment = "pre-commit/alpha.yaml"

[cargo-audit]
version = "${cargo_audit_version}"

[beta]
version = "2.0.0"
pre-commit-repository = "https://example.com/beta"
pre-commit-revision = "release-{version}"
TOML
}

write_config() {
  local alpha_revision=$1
  cat > "${test_root}/.pre-commit-config.yaml" << YAML
repos:
  - repo: https://example.com/alpha
    rev: ${alpha_revision}
    hooks:
      - id: alpha
  - repo: https://example.com/beta
    rev: release-2.0.0
    hooks:
      - id: beta
YAML
}

write_fragment() {
  cat > "${test_root}/pre-commit/alpha.yaml" << 'YAML'
- repo: https://example.com/alpha
  rev: v1.2.3
  hooks:
    - id: alpha
YAML
}

write_ci() {
  local install=${1:-}
  cat > "${test_root}/.github/workflows/ci.yaml" << YAML
jobs:
  check:
    steps:
      - run: version="\$(bash scripts/tool-version.sh alpha)" ${install}
YAML
}

write_ci_without_lookup() {
  cat > "${test_root}/.github/workflows/ci.yaml" << 'YAML'
jobs:
  check:
    steps:
      - run: echo no tool lookup
YAML
}

failures=0

expect_success() {
  local label=$1 output status=0
  output=$(python3 "${test_root}/scripts/check-tool-pins.py" 2>&1) || status=$?
  if [[ "$status" == 0 && "$output" == "Tool pins match tools.toml" ]]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s: exit %s\n%s\n' "$label" "$status" "$output" >&2
    failures=$((failures + 1))
  fi
}

expect_failure() {
  local label=$1 expected=$2 output status=0
  output=$(python3 "${test_root}/scripts/check-tool-pins.py" 2>&1) || status=$?
  if [[ "$status" == 1 && "$output" == *"$expected"* ]]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s: exit %s\n%s\n' "$label" "$status" "$output" >&2
    failures=$((failures + 1))
  fi
}

write_config v1.2.3
write_fragment
write_ci
write_catalog 0.22.2
expect_success "matching catalog, hooks, fragments, and CI"

for version in 0.22.2-alpha 0.22.2-beta.1 0.22.2-rc.1 0.22.2+local 0.22.2.1; do
  write_catalog "$version"
  expect_failure "unstable security tool pin $version" \
    "[cargo-audit].version must be a stable X.Y.Z release"
done
write_catalog 0.22.2

write_config v1.2.4
expect_failure "mismatched hook revision" "uses v1.2.4, expected v1.2.3"

write_config v1.2.3
write_ci 'alpha==1.2.3'
expect_failure "literal CI version" "hard-codes version 1.2.3"

write_ci_without_lookup
expect_failure "missing CI lookup" "missing tools.toml lookup for [alpha]"

write_ci
cat > "${test_root}/pre-commit/alpha.yaml" << 'YAML'
- repo: local
  hooks:
    - id: alpha
YAML
expect_failure "missing fragment entry" "missing tools.toml [alpha] repository"

cat >> "${test_root}/tools.toml" << 'TOML'
unexpected = true
TOML
expect_failure "unknown catalog field" "[beta] has unknown field(s): unexpected"

if ((failures > 0)); then
  printf '\n%s tool pin test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nAll tool pin tests passed\n'
