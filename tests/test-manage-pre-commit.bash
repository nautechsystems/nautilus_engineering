#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANAGER="${REPO_ROOT}/sync/manage_pre_commit.py"

for required in awk git python3; do
  command -v "$required" > /dev/null || {
    echo "Required test command not on PATH: $required" >&2
    exit 1
  }
done

test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-pre-commit-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
consumer="${test_root}/consumer"
fragment_dir="${consumer}/.nautilus-engineering/pre-commit"
mkdir -p "$fragment_dir"
cp "${REPO_ROOT}/pre-commit/shell.yaml" "${fragment_dir}/shell.yaml"
cp "${REPO_ROOT}/pre-commit/sync.yaml" "${fragment_dir}/sync.yaml"

shell_hash=$(python3 -c \
  'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' \
  "${fragment_dir}/shell.yaml")
sync_hash=$(python3 -c \
  'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' \
  "${fragment_dir}/sync.yaml")
cat > "${consumer}/.nautilus-engineering.lock" << TOML
version = 1
repository = "https://github.com/nautechsystems/nautilus_engineering"
revision = "0000000000000000000000000000000000000000"
manifest_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
marker_file = ".nautilus-engineering.syncing"
profiles = ["pre-commit"]

[[file]]
artifact = "pre-commit-shell"
path = ".nautilus-engineering/pre-commit/shell.yaml"
sha256 = "${shell_hash}"
executable = false

[[file]]
artifact = "pre-commit-sync"
path = ".nautilus-engineering/pre-commit/sync.yaml"
sha256 = "${sync_hash}"
executable = false
TOML

cat > "${consumer}/.pre-commit-config.yaml" << 'YAML'
default_stages: [pre-commit]

repos:
YAML
{
  awk '{ if (length) print "  " $0; else print "" }' "${fragment_dir}/shell.yaml"
  printf '\n'
  awk '{ if (length) print "  " $0; else print "" }' "${fragment_dir}/sync.yaml"
  cat << 'YAML'

  - repo: local
    hooks:
      - id: consumer-check
        name: consumer check
        entry: true
        language: system
YAML
} >> "${consumer}/.pre-commit-config.yaml"

git -C "$consumer" init --quiet

failures=0
status=0
output=$(cd "$consumer" && python3 "$MANAGER" render 2>&1) || status=$?
shfmt_count=$(grep -c -- '- id: shfmt' "${consumer}/.pre-commit-config.yaml")
if [[ "$status" == 0 && "$output" == *"Updated managed pre-commit section"* ]] &&
  [[ "$shfmt_count" == 1 ]] &&
  grep -Fq '  # nautilus-engineering: begin' "${consumer}/.pre-commit-config.yaml" &&
  grep -Fq -- '- id: check-nautilus-engineering-pre-commit' \
    "${consumer}/.pre-commit-config.yaml" &&
  grep -Fq -- '- id: consumer-check' "${consumer}/.pre-commit-config.yaml"; then
  printf 'ok   render absorbs exact shared entries and preserves local hooks\n'
else
  printf 'FAIL initial render: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

status=0
output=$(cd "$consumer" && python3 "$MANAGER" check 2>&1) || status=$?
if [[ "$status" == 0 && "$output" == *"matches vendored definitions"* ]]; then
  printf 'ok   worktree check accepts the rendered section\n'
else
  printf 'FAIL worktree check: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

git -C "$consumer" add -A
status=0
output=$(cd "$consumer" && python3 "$MANAGER" check --staged 2>&1) || status=$?
if [[ "$status" == 0 && "$output" == *"matches staged vendored definitions"* ]]; then
  printf 'ok   staged check reads the staged lock, fragments, and config\n'
else
  printf 'FAIL staged check: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

cat >> "${consumer}/.pre-commit-config.yaml" << 'YAML'

  - repo: https://github.com/scop/pre-commit-shfmt
    rev: v3.13.1-1
    hooks:
      - id: shfmt
YAML
status=0
output=$(cd "$consumer" && python3 "$MANAGER" check 2>&1) || status=$?
if [[ "$status" == 2 && "$output" == *"also appear outside the section"* &&
  "$output" == *"pre-commit-shell"* ]]; then
  printf 'ok   check rejects a selected definition duplicated outside the section\n'
else
  printf 'FAIL duplicate outside section: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi
git -C "$consumer" show :.pre-commit-config.yaml > "${consumer}/.pre-commit-config.yaml"

awk '{ if ($0 == "  # nautilus-engineering: end" && !changed) { print "  # drift"; changed=1 } print }' \
  "${consumer}/.pre-commit-config.yaml" > "${consumer}/config.tmp"
mv "${consumer}/config.tmp" "${consumer}/.pre-commit-config.yaml"
worktree_status=0
staged_status=0
worktree_output=$(cd "$consumer" && python3 "$MANAGER" check 2>&1) || worktree_status=$?
staged_output=$(cd "$consumer" && python3 "$MANAGER" check --staged 2>&1) || staged_status=$?
if [[ "$worktree_status" == 2 && "$worktree_output" == *"managed pre-commit section differs"* &&
  "$staged_status" == 0 ]]; then
  printf 'ok   worktree and staged checks inspect their named state\n'
else
  printf 'FAIL state checks: worktree %s, staged %s\n%s\n%s\n' \
    "$worktree_status" "$staged_status" "$worktree_output" "$staged_output" >&2
  failures=$((failures + 1))
fi

git -C "$consumer" show :.pre-commit-config.yaml > "${consumer}/.pre-commit-config.yaml"
cat >> "${consumer}/.pre-commit-config.yaml" << 'YAML'

  - repo: https://github.com/scop/pre-commit-shfmt
    rev: v3.13.1-1
    hooks:
      - id: shfmt
        exclude: local-shell-policy
YAML
status=0
output=$(cd "$consumer" && python3 "$MANAGER" render 2>&1) || status=$?
if [[ "$status" == 2 && "$output" == *"pre-commit definitions conflict"* &&
  "$output" == *"pre-commit-shell"* ]]; then
  printf 'ok   render rejects a local variant of a selected shared definition\n'
else
  printf 'FAIL conflicting definition: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

git -C "$consumer" show :.pre-commit-config.yaml > "${consumer}/.pre-commit-config.yaml"
awk '{ if ($0 == "  # nautilus-engineering: end" && !changed) { print "  # nautilus-engineering: begin"; changed=1; next } print }' \
  "${consumer}/.pre-commit-config.yaml" > "${consumer}/config.tmp"
mv "${consumer}/config.tmp" "${consumer}/.pre-commit-config.yaml"
status=0
output=$(cd "$consumer" && python3 "$MANAGER" check 2>&1) || status=$?
if [[ "$status" == 2 && "$output" == *"invalid managed-section markers"* ]]; then
  printf 'ok   check rejects duplicate or unmatched managed-section markers\n'
else
  printf 'FAIL invalid markers: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

if ((failures > 0)); then
  printf '\n%s managed pre-commit test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nAll managed pre-commit tests passed\n'
