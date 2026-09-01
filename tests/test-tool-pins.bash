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
releases = "pypi:alpha"
pre-commit-repository = "https://example.com/alpha"
pre-commit-revision = "v{version}"
pre-commit-fragment = "pre-commit/alpha.yaml"

[cargo-audit]
version = "${cargo_audit_version}"
releases = "crates:cargo-audit"

[beta]
version = "2.0.0"
releases = "github:example/beta"
pre-commit-repository = "https://example.com/beta"
pre-commit-revision = "release-{version}"

[gamma]
version = "3.0.0"
releases = "npm:gamma"
pre-commit-dependency = "cli:gamma:{version}"
pre-commit-hooks = ["gamma", "gamma-lint"]
pre-commit-fragment = "pre-commit/gamma.yaml"
TOML
}

write_config() {
  local alpha_revision=$1
  local gamma_version=${2:-3.0.0}
  local gamma_conflict=${3:-}
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
  - repo: local
    hooks:
      - id: gamma
        name: gamma
        entry: gamma
        language: rust
        additional_dependencies: &gamma_dependencies
          - cli:gamma:${gamma_version}
${gamma_conflict}
      - id: gamma-lint
        name: gamma-lint
        entry: gamma lint
        language: rust
        additional_dependencies: *gamma_dependencies
      - id: unrelated
        name: unrelated
        entry: unrelated
        language: rust
        additional_dependencies:
          - cli:gamma:3.0.0
YAML
}

write_fragment() {
  cat > "${test_root}/pre-commit/alpha.yaml" << 'YAML'
- repo: https://example.com/alpha
  rev: v1.2.3
  hooks:
    - id: alpha
YAML

  cat > "${test_root}/pre-commit/gamma.yaml" << 'YAML'
- repo: local
  hooks:
    - id: gamma
      name: gamma
      entry: gamma
      language: rust
      additional_dependencies:
        - cli:gamma:3.0.0
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

write_config v1.2.3 3.0.1
expect_failure "correct dependency on another hook does not mask owner drift" \
  "hook gamma is missing cli:gamma:3.0.0 from tools.toml [gamma]"

write_config v1.2.3 3.0.0 '          - cli:gamma:2.0.0'
expect_failure "conflicting owner dependency" \
  "hook gamma has conflicting dependencies: cli:gamma:2.0.0"

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

write_fragment
sed 's/cli:gamma:3.0.0/cli:gamma:3.0.1/' \
  "${test_root}/pre-commit/gamma.yaml" > "${test_root}/fragment.tmp"
mv "${test_root}/fragment.tmp" "${test_root}/pre-commit/gamma.yaml"
expect_failure "mismatched fragment dependency" \
  "missing cli:gamma:3.0.0 from tools.toml [gamma]"

cat >> "${test_root}/tools.toml" << 'TOML'
unexpected = true
TOML
expect_failure "unknown catalog field" "[gamma] has unknown field(s): unexpected"

write_catalog 0.22.2
cat >> "${test_root}/tools.toml" << 'TOML'

[delta]
version = "1.0.0"
TOML
expect_failure "missing release source" "[delta].releases must be"

for source in svn:delta github:delta crates:owner/delta "pypi:delta name"; do
  write_catalog 0.22.2
  cat >> "${test_root}/tools.toml" << TOML

[delta]
version = "1.0.0"
releases = "${source}"
TOML
  expect_failure "invalid release source ${source}" "[delta].releases must be"
done
write_catalog 0.22.2

if ((failures > 0)); then
  printf '\n%s tool pin test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nAll tool pin tests passed\n'
