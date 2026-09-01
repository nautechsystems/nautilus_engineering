#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

for required in git python3; do
  command -v "$required" > /dev/null || {
    echo "Required test command not on PATH: $required" >&2
    exit 1
  }
done

test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-adoption-status-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
source_repo="${test_root}/source"
mkdir -p "${source_repo}/config" "${source_repo}/scripts" "${source_repo}/standards" \
  "${source_repo}/sync"

cp "${REPO_ROOT}/scripts/report-adoption-status.py" "${source_repo}/scripts/"
cp "${REPO_ROOT}/sync/sync.py" "${source_repo}/sync/"
cat > "${source_repo}/standards/alpha.md" << 'TEXT'
alpha standard
TEXT
cat > "${source_repo}/config/beta.toml" << 'TEXT'
beta = 1
TEXT
cat > "${source_repo}/sync/manifest.toml" << 'TOML'
version = 1
repository = "https://github.com/example/source"
lock_file = ".nautilus-engineering.lock"
marker_file = ".nautilus-engineering.syncing"

[[artifact]]
id = "alpha-standard"
source = "standards/alpha.md"
target = "docs/alpha.md"
executable = false
profiles = ["docs"]

[[artifact]]
id = "beta-config"
source = "config/beta.toml"
target = ".beta.toml"
executable = false
profiles = ["config"]
TOML

git -C "$source_repo" init --quiet
git -C "$source_repo" config user.email test@example.com
git -C "$source_repo" config user.name Test
git -C "$source_repo" config commit.gpgsign false
git -C "$source_repo" add -A
git -C "$source_repo" commit --quiet -m first
rev1=$(git -C "$source_repo" rev-parse HEAD)
main_branch=$(git -C "$source_repo" symbolic-ref --short HEAD)

git -C "$source_repo" checkout --quiet -b side
printf 'side change\n' >> "${source_repo}/config/beta.toml"
git -C "$source_repo" commit --quiet -am side
side_rev=$(git -C "$source_repo" rev-parse HEAD)
git -C "$source_repo" checkout --quiet "$main_branch"

printf 'updated alpha standard\n' > "${source_repo}/standards/alpha.md"
git -C "$source_repo" commit --quiet -am second
rev2=$(git -C "$source_repo" rev-parse HEAD)

write_lock() {
  local consumer=$1 revision=$2
  shift 2
  mkdir -p "$consumer"
  cat > "${consumer}/.nautilus-engineering.lock" << LOCK
version = 1
repository = "${LOCK_REPOSITORY:-https://github.com/example/source}"
revision = "${revision}"
manifest_sha256 = "$(printf '0%.0s' {1..64})"
marker_file = ".nautilus-engineering.syncing"
profiles = ["docs"]
LOCK
  local artifact path
  for artifact in "$@"; do
    case "$artifact" in
      alpha-standard) path="docs/alpha.md" ;;
      beta-config) path=".beta.toml" ;;
      *) path="managed/${artifact}" ;;
    esac
    cat >> "${consumer}/.nautilus-engineering.lock" << LOCK

[[file]]
artifact = "${artifact}"
path = "${path}"
sha256 = "$(printf '1%.0s' {1..64})"
executable = false
LOCK
  done
}

write_lock "${test_root}/consumer_behind" "$rev1" alpha-standard
write_lock "${test_root}/consumer_current" "$rev2" alpha-standard beta-config
write_lock "${test_root}/consumer_legacy" "$rev2" alpha-standard beta-config \
  legacy-check-alpha legacy-check-bravo legacy-check-charlie legacy-check-delta \
  legacy-check-echo legacy-check-foxtrot legacy-check-golf legacy-check-hotel
write_lock "${test_root}/consumer_badrev" "$(printf 'd%.0s' {1..40})" alpha-standard
LOCK_REPOSITORY="https://github.com/example/other" \
  write_lock "${test_root}/consumer_foreign" "$rev2" alpha-standard

failures=0

run_report() {
  status=0
  output=$(python3 -B "${source_repo}/scripts/report-adoption-status.py" "$@" 2>&1) ||
    status=$?
}

expect_report() {
  local label=$1 expected_status=$2
  shift 2
  local arguments=()
  while (($# > 0)) && [[ "$1" != -- ]]; do
    arguments+=("$1")
    shift
  done
  [[ "${1:-}" == -- ]] && shift
  run_report ${arguments[@]+"${arguments[@]}"}
  if [[ "$status" != "$expected_status" ]]; then
    printf 'FAIL %s: exit %s, expected %s\n%s\n' "$label" "$status" "$expected_status" \
      "$output" >&2
    failures=$((failures + 1))
    return
  fi
  local expected
  for expected in "$@"; do
    if [[ "$output" != *"$expected"* ]]; then
      printf 'FAIL %s: missing %q\n%s\n' "$label" "$expected" "$output" >&2
      failures=$((failures + 1))
      return
    fi
  done
  printf 'ok   %s\n' "$label"
}

expect_absent() {
  local label=$1 unexpected=$2
  if [[ "$output" == *"$unexpected"* ]]; then
    printf 'FAIL %s: found %q\n%s\n' "$label" "$unexpected" "$output" >&2
    failures=$((failures + 1))
  else
    printf 'ok   %s\n' "$label"
  fi
}

short2=${rev2:0:7}

expect_report "explicit consumer paths are required" 2 -- \
  "Error: specify at least one consumer repository root"
expect_absent "missing paths do not scan neighboring directories" "consumer_behind"

expect_report "behind and current consumers report drift" 1 \
  "${test_root}/consumer_behind" "${test_root}/consumer_current" -- \
  "Adoption status for 2 consumer(s) against ${short2}" \
  "1 of 2 consumer(s) are behind ${short2}"

expect_report "current consumer alone reports success" 0 \
  "${test_root}/consumer_current" -- \
  "${short2}  current" \
  "All 1 consumer(s) are current at ${short2}"
expect_absent "fully adopted consumer lists nothing unadopted" "unadopted"

write_lock "${test_root}/consumer_bad_hash" "$rev2" alpha-standard
sed 's/^manifest_sha256 = .*/manifest_sha256 = "bad"/' \
  "${test_root}/consumer_bad_hash/.nautilus-engineering.lock" \
  > "${test_root}/consumer_bad_hash/.nautilus-engineering.lock.tmp"
mv "${test_root}/consumer_bad_hash/.nautilus-engineering.lock.tmp" \
  "${test_root}/consumer_bad_hash/.nautilus-engineering.lock"
expect_report "invalid current lock metadata is reported" 2 \
  "${test_root}/consumer_bad_hash" -- \
  "error: existing sync lock has an invalid manifest hash" \
  "1 consumer report(s) failed"

run_report "${test_root}/consumer_legacy"
long_lines=$(awk 'length > 100' <<< "$output")
wrapped_lines=$(grep -c 'legacy-check-' <<< "$output" || true)
if [[ "$status" == 0 && -z "$long_lines" && "$wrapped_lines" == 3 &&
  "$output" == *"removed from manifest (8): legacy-check-alpha,"* &&
  "$output" == *"legacy-check-hotel"* ]]; then
  printf 'ok   %s\n' "removed artifact list wraps within 100 columns"
else
  printf 'FAIL %s\n%s\n' "removed artifact list wraps within 100 columns" "$output" >&2
  failures=$((failures + 1))
fi

write_lock "${test_root}/consumer_side" "$side_rev" alpha-standard
expect_report "unmerged lock revision is reported" 2 \
  "${test_root}/consumer_side" -- \
  "error: lock revision ${side_rev:0:7} is not an ancestor of HEAD" \
  "1 consumer report(s) failed"

mkdir -p "${test_root}/consumer_empty"
expect_report "missing lock is reported for an explicit consumer" 2 \
  "${test_root}/consumer_empty" -- \
  "error: sync lock not found:" \
  "1 consumer report(s) failed"

mkdir -p "${test_root}/consumer_broken"
printf 'not toml [' > "${test_root}/consumer_broken/.nautilus-engineering.lock"
expect_report "malformed lock is reported" 2 \
  "${test_root}/consumer_broken" -- \
  "error: cannot read sync lock:" \
  "1 consumer report(s) failed"

if ((failures > 0)); then
  printf '\n%s adoption status test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nAll adoption status tests passed\n'
