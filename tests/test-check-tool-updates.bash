#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

for required in awk curl git jq python3; do
  command -v "$required" > /dev/null || {
    echo "Required test command not on PATH: $required" >&2
    exit 1
  }
done

test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-tool-updates-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

mkdir -p "${test_root}/scripts"
cp "${REPO_ROOT}/scripts/check-tool-updates.bash" "${test_root}/scripts/"

fake_bin="${test_root}/bin"
mkdir -p "$fake_bin"

cat > "${fake_bin}/curl" << 'FAKE_CURL'
#!/usr/bin/env bash
set -u
url=""
for arg in "$@"; do
  case "$arg" in
    https://*) url="$arg" ;;
  esac
done
lookup() {
  grep -E "^$1 $2 " "$FAKE_RELEASES_FIXTURE" 2> /dev/null | awk '{print $3}'
}
published() {
  grep -E "^$1 $2 " "$FAKE_RELEASES_FIXTURE" 2> /dev/null | awk '{print $4}'
}
case "$url" in
  https://crates.io/api/v1/crates/*)
    version="$(lookup crates "${url##*/}")"
    released="$(published crates "${url##*/}")"
    [[ -n "$version" && -n "$released" ]] || exit 22
    printf '{"crate":{"max_stable_version":"%s"},"versions":[{"num":"%s","created_at":"%s"}]}\n' \
      "$version" "$version" "$released"
    ;;
  https://pypi.org/pypi/*/json)
    package="${url%/json}"
    version="$(lookup pypi "${package##*/}")"
    released="$(published pypi "${package##*/}")"
    [[ -n "$version" && -n "$released" ]] || exit 22
    printf '{"info":{"version":"%s"},"urls":[{"upload_time_iso_8601":"%s"}]}\n' \
      "$version" "$released"
    ;;
  https://registry.npmjs.org/*)
    package="${url##*/}"
    version="$(lookup npm "${package##*/}")"
    released="$(published npm "${package##*/}")"
    [[ -n "$version" && -n "$released" ]] || exit 22
    printf '{"dist-tags":{"latest":"%s"},"time":{"%s":"%s"}}\n' \
      "$version" "$version" "$released"
    ;;
  https://api.github.com/repos/*/releases/latest)
    package="${url#https://api.github.com/repos/}"
    version="$(lookup github "${package%/releases/latest}")"
    released="$(published github "${package%/releases/latest}")"
    [[ -n "$version" && -n "$released" ]] || exit 22
    printf '{"tag_name":"v%s","published_at":"%s"}\n' "$version" "$released"
    ;;
  https://api.github.com/repos/*/git/tags/*)
    path="${url#https://api.github.com/repos/}"
    package="${path%/git/tags/*}"
    released="$(published github-tags "$package")"
    [[ -n "$released" ]] || exit 22
    printf '{"tagger":{"date":"%s"}}\n' "$released"
    ;;
  https://api.github.com/repos/*/commits/*)
    path="${url#https://api.github.com/repos/}"
    package="${path%/commits/*}"
    released="$(published github-tags "$package")"
    [[ -n "$released" ]] || exit 22
    printf '{"commit":{"committer":{"date":"%s"}}}\n' "$released"
    ;;
  *)
    exit 22
    ;;
esac
FAKE_CURL
chmod +x "${fake_bin}/curl"

cat > "${fake_bin}/git" << 'FAKE_GIT'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == "ls-remote" && "${2:-}" == "--tags" ]]; then
  [[ "${GIT_TERMINAL_PROMPT:-}" == 0 ]] || exit 2
  url="${3:?}"
  package="${url#https://github.com/}"
  matched=$(grep -E "^${package} " "$FAKE_TAGS_FIXTURE" 2> /dev/null | awk '{print $2}')
  [[ -n "$matched" ]] || exit 128
  index=0
  while IFS= read -r tag; do
    index=$((index + 1))
    printf '%040d\trefs/tags/%s\n' "$index" "$tag"
  done <<< "$matched"
  exit 0
fi
exit 1
FAKE_GIT
chmod +x "${fake_bin}/git"

fixture="${test_root}/releases.txt"
tags_fixture="${test_root}/tags.txt"
export FAKE_RELEASES_FIXTURE="$fixture"
export FAKE_TAGS_FIXTURE="$tags_fixture"

write_catalog() {
  cat > "${test_root}/tools.toml" << 'TOML'
[alpha]
version = "1.2.3"
releases = "crates:alpha-cli"

[beta]
version = "2.0.0"
releases = "pypi:beta"

[gamma]
version = "0.11.0.1"
releases = "npm:gamma"

[delta]
version = "3.1.0"
releases = "github:example/delta"

[epsilon]
version = "0.10.0"
releases = "github-tags:example/epsilon"
TOML
}

write_fixture() {
  local alpha_version=${1:-1.2.3}
  local alpha_released=${2:-$older_release}
  cat > "$fixture" << FIXTURE
crates alpha-cli ${alpha_version} ${alpha_released}
pypi beta 2.0.0 ${older_release}
npm gamma 0.11.0.1 ${older_release}
github example/delta 3.1.0 ${older_release}
github-tags example/epsilon 0.10.0 ${older_release}
FIXTURE
  cat > "$tags_fixture" << 'FIXTURE'
example/epsilon v0.9.0
example/epsilon v0.10.0
example/epsilon v0.10.0^{}
example/epsilon v0.11.0-rc1
FIXTURE
}

failures=0
recent_release=$(jq -nr 'now - (36 * 3600) | todateiso8601')
older_release=$(jq -nr 'now - (5 * 86400 + 12 * 3600) | todateiso8601')

run_report() {
  status=0
  output=$(PATH="${fake_bin}:$PATH" bash "${test_root}/scripts/check-tool-updates.bash" 2>&1) ||
    status=$?
}

expect_report() {
  local label=$1 expected_status=$2
  shift 2
  run_report
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

write_catalog
write_fixture
expect_report "all pins current across every release source" 0 \
  "released (UTC)" \
  "5d 12h" \
  "All 5 tool pin(s) match their latest upstream releases"
expect_absent "current report has no outdated flag" "** OUTDATED"

write_fixture 1.3.0 "$recent_release"
expect_report "outdated crates pin is flagged" 1 \
  "alpha                1.2.3        1.3.0" \
  "1d 12h  ** OUTDATED" \
  "1 tool pin(s) differ from the latest upstream release:" \
  "alpha 1.2.3 -> 1.3.0"

orange=$(printf '\033[38;5;208m')
output=$(
  PATH="${fake_bin}:$PATH" python3 - "${test_root}/scripts/check-tool-updates.bash" << 'PY'
import os
import pty
import sys

os.environ.pop("NO_COLOR", None)
pty.spawn(["bash", sys.argv[1]])
PY
)
if [[ "$output" == *"${orange}  1d 12h"* ]]; then
  printf 'ok   %s\n' "release within three days is orange in a terminal"
else
  printf 'FAIL %s\n%s\n' "release within three days is orange in a terminal" "$output" >&2
  failures=$((failures + 1))
fi

write_fixture
sed 's/^github example\/delta 3.1.0 /github example\/delta 3.2.0 /' "$fixture" \
  > "${fixture}.tmp"
mv "${fixture}.tmp" "$fixture"
expect_report "github release tag drops its v prefix" 1 "delta 3.1.0 -> 3.2.0"

write_fixture
cat > "$tags_fixture" << 'FIXTURE'
example/epsilon v0.10.0
example/epsilon v0.9.0
example/epsilon v0.9.0^{}
FIXTURE
expect_report "github tags sort numerically, not lexically" 0 \
  "All 5 tool pin(s) match their latest upstream releases"

write_fixture
grep -v '^pypi beta ' "$fixture" > "${fixture}.tmp"
mv "${fixture}.tmp" "$fixture"
expect_report "unreachable release source fails the report" 1 \
  "beta                 2.0.0        LOOKUP FAILED" \
  "FAIL: 1 release lookup(s) failed:" \
  "beta: no release found at pypi:beta"

write_fixture
cat >> "${test_root}/tools.toml" << 'TOML'

[zeta]
version = "1.0.0"
releases = "svn:zeta"
TOML
expect_report "unsupported release source fails the report" 1 \
  "zeta                 1.0.0        INVALID RELEASE SOURCE" \
  "zeta: unsupported release source svn:zeta"

write_catalog
cat >> "${test_root}/tools.toml" << 'TOML'

[zeta]
version = "1.0.0"
TOML
expect_report "missing releases field fails the report" 1 \
  "zeta                 1.0.0        INVALID CATALOG ENTRY" \
  "zeta: missing version or releases field"

if ((failures > 0)); then
  printf '\n%s tool update test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nAll tool update tests passed\n'
