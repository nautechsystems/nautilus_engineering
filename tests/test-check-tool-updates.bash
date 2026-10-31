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
# set -e and pipefail omitted: fixture lookups fail freely before the explicit
# exit-22 guards handle them
set -u
url=""
for arg in "$@"; do
  case "$arg" in
    https://*) url="$arg" ;;
  esac
done
line() {
  grep -E "^$1 $2 " "$FAKE_RELEASES_FIXTURE" 2> /dev/null
}
latest_version() {
  line "$1" "$2" | awk '{print $3}'
}
latest_released() {
  line "$1" "$2" | awk '{print $4}'
}
time_of() {
  line "$1" "$2" | awk -v version="$3" '{
    for (i = 3; i <= NF; i += 2) if ($i == version) print $(i + 1)
  }'
}
tag_version_at() {
  grep -E "^$1 " "$FAKE_TAGS_FIXTURE" 2> /dev/null |
    awk -v n="$2" 'NR == n { sub(/^v/, "", $2); sub(/\^\{\}$/, "", $2); print $2 }'
}
case "$url" in
  https://crates.io/api/v1/crates/*)
    package="${url##*/}"
    version="$(latest_version crates "$package")"
    released="$(latest_released crates "$package")"
    [[ -n "$version" && -n "$released" ]] || exit 22
    versions=$(line crates "$package" | awk '{
      printf "["
      for (i = 3; i <= NF; i += 2) {
        printf "%s{\"num\":\"%s\",\"created_at\":\"%s\",\"yanked\":false}", \
          ((i > 3) ? "," : ""), $i, $(i + 1)
      }
      printf "]"
    }')
    printf '{"crate":{"max_stable_version":"%s"},"versions":%s}\n' "$version" "$versions"
    ;;
  https://pypi.org/pypi/*/json)
    package="${url%/json}"
    package="${package##*/}"
    version="$(latest_version pypi "$package")"
    released="$(latest_released pypi "$package")"
    [[ -n "$version" && -n "$released" ]] || exit 22
    releases=$(line pypi "$package" | awk '{
      printf "{"
      separator = ""
      for (i = 3; i <= NF; i += 2) {
        printf "%s\"%s\":[{\"upload_time_iso_8601\":\"%s\"}]", separator, $i, $(i + 1)
        separator = ","
      }
      printf "}"
    }')
    printf '{"info":{"version":"%s"},"urls":[{"upload_time_iso_8601":"%s"}],"releases":%s}\n' \
      "$version" "$released" "$releases"
    ;;
  https://registry.npmjs.org/*)
    package="${url#https://registry.npmjs.org/}"
    [[ "$package" != */* ]] || exit 22
    package=${package/\%2f/\/}
    version="$(latest_version npm "$package")"
    released="$(latest_released npm "$package")"
    [[ -n "$version" && -n "$released" ]] || exit 22
    times=$(line npm "$package" | awk '{
      printf "{"
      for (i = 3; i <= NF; i += 2) {
        printf "%s\"%s\":\"%s\"", ((i > 3) ? "," : ""), $i, $(i + 1)
      }
      printf "}"
    }')
    printf '{"dist-tags":{"latest":"%s"},"time":%s}\n' "$version" "$times"
    ;;
  https://api.github.com/repos/*/releases/latest)
    package="${url#https://api.github.com/repos/}"
    package="${package%/releases/latest}"
    version="$(latest_version github "$package")"
    released="$(latest_released github "$package")"
    [[ -n "$version" && -n "$released" ]] || exit 22
    printf '{"tag_name":"v%s","published_at":"%s"}\n' "$version" "$released"
    ;;
  https://api.github.com/repos/*/releases?per_page=100)
    package="${url#https://api.github.com/repos/}"
    package="${package%%/releases*}"
    [[ "${FAKE_RELEASES_LIST_FAIL:-}" == "$package" ]] && exit 22
    line github "$package" | awk '{
      printf "["
      for (i = 3; i <= NF; i += 2) {
        printf "%s{\"tag_name\":\"v%s\",\"published_at\":\"%s\",\"prerelease\":false}", \
          ((i > 3) ? "," : ""), $i, $(i + 1)
      }
      printf "]"
    }'
    ;;
  https://api.github.com/repos/*/git/tags/*)
    path="${url#https://api.github.com/repos/}"
    package="${path%/git/tags/*}"
    version="$(tag_version_at "$package" "$((10#${url##*/}))")"
    released="$(time_of github-tags "$package" "$version")"
    [[ -n "$released" ]] || exit 22
    printf '{"tagger":{"date":"%s"}}\n' "$released"
    ;;
  https://api.github.com/repos/*/commits/*)
    path="${url#https://api.github.com/repos/}"
    package="${path%/commits/*}"
    version="$(tag_version_at "$package" "$((10#${url##*/}))")"
    released="$(time_of github-tags "$package" "$version")"
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
# set -e omitted: no fixture match is handled by the explicit exit statuses
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

export TOOL_UPDATES_REAL_JQ
TOOL_UPDATES_REAL_JQ=$(command -v jq)
export TOOL_UPDATES_NOW=1802995200
cat > "${fake_bin}/jq" << 'FAKE_JQ'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# == 2 && "$1" == -nr && "$2" == 'now | floor' ]]; then
  printf '%s\n' "$TOOL_UPDATES_NOW"
  exit 0
fi
exec "$TOOL_UPDATES_REAL_JQ" "$@"
FAKE_JQ
chmod +x "${fake_bin}/jq"

fixture="${test_root}/releases.txt"
tags_fixture="${test_root}/tags.txt"
export FAKE_RELEASES_FIXTURE="$fixture"
export FAKE_TAGS_FIXTURE="$tags_fixture"

write_catalog() {
  cat > "${test_root}/tools.toml" << 'TOML'
[alpha]
kind = "tool"
version = "1.2.3"
releases = "crates:alpha-cli"

[beta]
kind = "python"
version = "2.0.0"
releases = "pypi:beta"

[gamma]
kind = "tool"
version = "0.11.0.1"
releases = "npm:gamma"

[delta]
kind = "tool"
version = "3.1.0"
releases = "github:example/delta"

[epsilon]
kind = "tool"
version = "0.10.0"
releases = "github-tags:example/epsilon"
TOML
}

# Each fixture line lists the latest release first, then any older history as
# additional "version time" pairs.
write_fixture() {
  local alpha_version=${1:-1.2.3}
  local alpha_released=${2:-$older_release}
  local alpha_history=${3:-}
  cat > "$fixture" << FIXTURE
crates alpha-cli ${alpha_version} ${alpha_released} ${alpha_history}
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
recent_release=$(jq -nr --argjson now "$TOOL_UPDATES_NOW" '$now - (36 * 3600) | todateiso8601')
mature_release=$(jq -nr --argjson now "$TOOL_UPDATES_NOW" '$now - (8 * 86400 + 12 * 3600) | todateiso8601')
older_release=$(jq -nr --argjson now "$TOOL_UPDATES_NOW" '$now - (5 * 86400 + 12 * 3600) | todateiso8601')

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
  "name                 kind           pinned       latest       released (UTC)" \
  "Cooldowns: Python packages and uv 7 days; other tools 3 days" \
  "alpha                tool           1.2.3" \
  "beta                 python         2.0.0" \
  "5d 12h" \
  "All 5 tool pin(s) match their latest upstream releases"
expect_absent "current report has no outdated flag" "** OUTDATED"
expect_absent "current pins have no upgradeable flag" "** UPGRADEABLE"
expect_absent "redirected report has no ANSI colors" $'\033['

write_fixture 1.3.0 "$recent_release" "1.2.3 $older_release"
expect_report "differing pin with no newer release past the cooldown is a hold" 0 \
  "alpha                tool           1.2.3        1.3.0" \
  "1d 12h  ** RECENT" \
  $'\n\nCooldown holds (1): every newer release is within its cooldown' \
  "alpha 1.2.3 -> 1.3.0 (1d 12h within cooldown)" \
  "delta                tool           3.1.0        3.1.0" \
  "epsilon              tool           0.10.0       0.10.0"
expect_absent "hold report has no outdated flag" "** OUTDATED"
expect_absent "hold report does not claim all pins match" "All 5 tool pin(s) match"
expect_absent "hold does not repeat the pin as a previous row" $'\n                                                 1.2.3'

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

write_fixture 1.3.0 "$recent_release" "1.2.12 $recent_release 1.2.11 $older_release 1.2.10 $older_release"
expect_report "newest past-cooldown release is the upgrade target" 1 \
  "alpha                tool           1.2.3        1.3.0" \
  "1d 12h  ** RECENT" \
  $'\n                                                 1.2.11' \
  $'\n                                                 1.2.10' \
  "5d 12h  ** UPGRADEABLE" \
  $'\n\nUpgradable pins (1): newest release past its cooldown' \
  "alpha 1.2.3 -> 1.2.11 (latest 1.3.0 within cooldown)"
expect_absent "target report has no hold section" "Cooldown holds"
if [[ "$output" == *$'\n                                                 1.2.11'*$'\n                                                 1.2.10'* ]]; then
  printf 'ok   %s\n' "intervening rows are newest first"
else
  printf 'FAIL %s\n%s\n' "intervening rows are newest first" "$output" >&2
  failures=$((failures + 1))
fi

release_statuses=$(printf '%s\n' "$output" | awk '$1 ~ /^1\.2\.(12|11|10)$/ { print $1, $NF }')
if [[ "$release_statuses" == $'1.2.12 12h\n1.2.11 UPGRADEABLE\n1.2.10 UPGRADEABLE' ]]; then
  printf 'ok   %s\n' "each intermediate release is labeled only after its cooldown"
else
  printf 'FAIL %s\n%s\n' "intermediate release statuses" "$output" >&2
  failures=$((failures + 1))
fi

green=$(printf '\033[0;32m')
reset=$(printf '\033[0m')
for color_mode in enabled disabled; do
  output=$(
    PATH="${fake_bin}:$PATH" python3 - "${test_root}/scripts/check-tool-updates.bash" "$color_mode" << 'PY_UPGRADE'
import os
import pty
import sys

if sys.argv[2] == "disabled":
    os.environ["NO_COLOR"] = ""
else:
    os.environ.pop("NO_COLOR", None)
pty.spawn(["bash", sys.argv[1]])
PY_UPGRADE
  )
  if [[ "$color_mode" == enabled ]]; then
    if [[ "$output" == *"${green}  5d 12h  ** UPGRADEABLE${reset}"* ]]; then
      printf 'ok   %s\n' "eligible intermediate releases have green age and status"
    else
      printf 'FAIL %s\n%s\n' "eligible intermediate release colors" "$output" >&2
      failures=$((failures + 1))
    fi
  else
    expect_absent "NO_COLOR disables terminal colors" $'\033['
    if [[ "$output" == *"5d 12h  ** UPGRADEABLE"* ]]; then
      printf 'ok   %s\n' "NO_COLOR preserves upgradeable labels"
    else
      printf 'FAIL %s\n%s\n' "NO_COLOR upgradeable labels" "$output" >&2
      failures=$((failures + 1))
    fi
  fi
done

write_fixture 1.3.0 "$recent_release" "1.2.11 $recent_release 1.2.9 $recent_release 1.2.3 $older_release"
expect_report "hold lists every newer release between pin and latest" 0 \
  "alpha                tool           1.2.3        1.3.0" \
  $'\n                                                 1.2.11' \
  $'\n                                                 1.2.9' \
  "alpha 1.2.3 -> 1.3.0 (1d 12h within cooldown)"
expect_absent "hold between rows omit the tool name" $'\nalpha                tool           1.2.3        1.2.11'
expect_absent "recent intermediate releases are not upgradeable" "** UPGRADEABLE"

write_fixture
sed "s|^pypi beta 2.0.0 .*|pypi beta 2.1.0 ${recent_release} 2.0.9 ${older_release} 2.0.5 ${mature_release}|" \
  "$fixture" > "${fixture}.tmp"
mv "${fixture}.tmp" "$fixture"
expect_report "pypi history yields the upgrade target" 1 \
  "beta                 python         2.0.0        2.1.0" \
  $'\n                                                 2.0.5' \
  "beta 2.0.0 -> 2.0.5 (latest 2.1.0 within cooldown)"
expect_absent "Python target excludes releases between three and seven days" "beta 2.0.0 -> 2.0.9"

write_catalog
write_fixture
sed "s|^pypi beta 2.0.0 .*|pypi beta 2.1.0 ${older_release}|" \
  "$fixture" > "${fixture}.tmp"
mv "${fixture}.tmp" "$fixture"
cat >> "${test_root}/tools.toml" << 'TOML'

[native]
kind = "tool"
version = "4.0.0"
releases = "pypi:native"

[uv]
kind = "tool"
version = "0.13.0"
releases = "pypi:uv"
TOML
printf 'pypi native 4.1.0 %s\n' "$older_release" >> "$fixture"
printf 'pypi uv 0.13.5 %s\n' "$older_release" >> "$fixture"
expect_report "Python packages and uv wait seven days while other PyPI tools wait three" 1 \
  "beta                 python         2.0.0        2.1.0" \
  "native               tool           4.0.0        4.1.0" \
  "uv                   tool           0.13.0       0.13.5" \
  "Upgradable pins (1): newest release past its cooldown" \
  "native 4.0.0 -> 4.1.0" \
  "Cooldown holds (2): every newer release is within its cooldown" \
  "beta 2.0.0 -> 2.1.0 (5d 12h within cooldown)" \
  "uv 0.13.0 -> 0.13.5 (5d 12h within cooldown)"

output=$(
  PATH="${fake_bin}:$PATH" python3 - "${test_root}/scripts/check-tool-updates.bash" << 'PY_COLOR'
import os
import pty
import sys

os.environ.pop("NO_COLOR", None)
pty.spawn(["bash", sys.argv[1]])
PY_COLOR
)
if [[ "$output" == *"${orange}  5d 12h"* &&
  "$output" == *"${green}  5d 12h  ** UPGRADEABLE${reset}"* ]]; then
  printf 'ok   %s\n' "Python package at five days is orange while native tool is upgradeable"
else
  printf 'FAIL %s\n%s\n' "per-kind terminal colors" "$output" >&2
  failures=$((failures + 1))
fi

sed "s|^pypi uv .*|pypi uv 0.13.5 ${recent_release} 0.13.4 ${older_release} 0.13.3 ${mature_release}|" \
  "$fixture" > "${fixture}.tmp"
mv "${fixture}.tmp" "$fixture"
expect_report "uv upgrade target excludes releases between three and seven days" 1 \
  "uv 0.13.0 -> 0.13.3 (latest 0.13.5 within cooldown)"
expect_absent "uv does not target the five-day release" "uv 0.13.0 -> 0.13.4"

write_catalog
write_fixture
sed '/^\[delta\]$/,/^$/s/kind = "tool"/kind = "python"/' \
  "${test_root}/tools.toml" > "${test_root}/tools.toml.tmp"
mv "${test_root}/tools.toml.tmp" "${test_root}/tools.toml"
sed "s|^github example/delta 3.1.0 .*|github example/delta 3.2.0 ${older_release}|" \
  "$fixture" > "${fixture}.tmp"
mv "${fixture}.tmp" "$fixture"
expect_report "Python packages on GitHub also wait seven days" 0 \
  "delta                python         3.1.0        3.2.0" \
  "delta 3.1.0 -> 3.2.0 (5d 12h within cooldown)"
expect_absent "GitHub Python package has no eligible upgrade" "Upgradable pins"

for kind_days in 'beta tool 3' 'beta python 7' 'uv tool 7'; do
  read -r boundary_name boundary_kind boundary_days <<< "$kind_days"
  cat > "${test_root}/tools.toml" << TOML
[$boundary_name]
kind = "$boundary_kind"
version = "2.0.0"
releases = "pypi:$boundary_name"
TOML
  for remaining in 1 0; do
    boundary_release=$(jq -nr --argjson now "$TOOL_UPDATES_NOW" \
      --argjson days "$boundary_days" --argjson remaining "$remaining" \
      '$now - $days * 86400 + $remaining | todateiso8601')
    printf 'pypi %s 2.1.0 %s\n' "$boundary_name" "$boundary_release" > "$fixture"
    if [[ "$remaining" == 1 ]]; then
      expect_report "$boundary_name $boundary_kind holds one second before $boundary_days days" 0 \
        "Cooldown holds (1): every newer release is within its cooldown"
      expect_absent "boundary hold has no upgrade" "Upgradable pins"
      expect_absent "boundary hold has no upgradeable flag" "** UPGRADEABLE"
    else
      expect_report "$boundary_name $boundary_kind allows a release at exactly $boundary_days days" 1 \
        "Upgradable pins (1): newest release past its cooldown" \
        "$boundary_name 2.0.0 -> 2.1.0" \
        "${boundary_days}d  0h  ** UPGRADEABLE"
      expect_absent "eligible boundary has no hold" "Cooldown holds"
    fi
  done
done
write_catalog

write_fixture
sed "s|^npm gamma 0.11.0.1 .*|npm gamma 0.12.0 ${recent_release} 0.11.5 ${older_release}|" \
  "$fixture" > "${fixture}.tmp"
mv "${fixture}.tmp" "$fixture"
expect_report "npm history yields the upgrade target" 1 \
  "gamma                tool           0.11.0.1     0.12.0" \
  $'\n                                                 0.11.5' \
  "gamma 0.11.0.1 -> 0.11.5 (latest 0.12.0 within cooldown)"

write_fixture
sed "s|^npm gamma 0.11.0.1 .*|npm gamma 0.12.0 ${older_release} 0.13.0 ${older_release}|" \
  "$fixture" > "${fixture}.tmp"
mv "${fixture}.tmp" "$fixture"
expect_report "eligible npm latest is labeled when a higher upgrade target exists" 1 \
  "gamma                tool           0.11.0.1     0.12.0" \
  "5d 12h  ** UPGRADEABLE" \
  "gamma 0.11.0.1 -> 0.13.0 (latest 0.12.0)"
expect_absent "eligible npm latest is not outdated" "** OUTDATED"

write_fixture
sed "s|^github example/delta 3.1.0 .*|github example/delta 3.3.0 ${recent_release} 3.2.0 ${older_release}|" \
  "$fixture" > "${fixture}.tmp"
mv "${fixture}.tmp" "$fixture"
expect_report "github release history yields the upgrade target" 1 \
  "delta                tool           3.1.0        3.3.0" \
  $'\n                                                 3.2.0' \
  "delta 3.1.0 -> 3.2.0 (latest 3.3.0 within cooldown)"

write_fixture
sed "s|^github-tags example/epsilon 0.10.0 .*|github-tags example/epsilon 0.11.0 ${recent_release} 0.10.5 ${older_release} 0.10.0 ${older_release}|" \
  "$fixture" > "${fixture}.tmp"
mv "${fixture}.tmp" "$fixture"
cat > "$tags_fixture" << 'FIXTURE'
example/epsilon v0.9.0
example/epsilon v0.10.0
example/epsilon v0.10.0^{}
example/epsilon v0.10.5
example/epsilon v0.10.5^{}
example/epsilon v0.11.0
example/epsilon v0.11.0^{}
FIXTURE
expect_report "github tag walk yields the upgrade target" 1 \
  "epsilon              tool           0.10.0       0.11.0" \
  $'\n                                                 0.10.5' \
  "epsilon 0.10.0 -> 0.10.5 (latest 0.11.0 within cooldown)"

write_catalog
write_fixture
cat >> "${test_root}/tools.toml" << 'TOML'

[eta]
kind = "tool"
version = "1.0.0.0.10"
releases = "crates:eta-cli"
TOML
echo "crates eta-cli 1.0.0.0.20 ${recent_release} 1.0.0.0.2 ${older_release}" >> "$fixture"
expect_report "five-segment pins compare beyond four sort keys" 0 \
  "eta                  tool           1.0.0.0.10   1.0.0.0.20" \
  "eta 1.0.0.0.10 -> 1.0.0.0.20 (1d 12h within cooldown)"
expect_absent "five-segment hold is not an upgrade target" "eta 1.0.0.0.10 -> 1.0.0.0.2 (latest"
expect_absent "older five-segment release is not listed" $'\n                                                 1.0.0.0.2'

write_catalog
write_fixture
sed "s|^crates alpha-cli 1.2.3 .*|crates alpha-cli 1.1.0 ${older_release}|" \
  "$fixture" > "${fixture}.tmp"
mv "${fixture}.tmp" "$fixture"
expect_report "pin ahead of upstream is a mismatch" 1 \
  "alpha                tool           1.2.3        1.1.0" \
  "5d 12h  ** OUTDATED" \
  "Pin mismatches (1): latest upstream release is not newer than the pin" \
  "alpha 1.2.3 (latest 1.1.0 is not newer)"
expect_absent "mismatch is not a cooldown hold" "Cooldown holds"
expect_absent "mismatched pin is not upgradeable" "** UPGRADEABLE"

write_fixture
sed "s|^pypi beta 2.0.0 .*|pypi beta 2.0.0rc1 ${mature_release} 2.0.5 ${mature_release}|" \
  "$fixture" > "${fixture}.tmp"
mv "${fixture}.tmp" "$fixture"
expect_report "non-numeric latest gets a neutral target suffix" 1 \
  "beta                 python         2.0.0        2.0.0rc1" \
  "8d 12h  ** OUTDATED" \
  "beta 2.0.0 -> 2.0.5 (latest 2.0.0rc1)"
expect_absent "neutral suffix does not claim a cooldown" "within cooldown"
expect_absent "past-cooldown latest lists no intervening row" $'\n                                                 2.0.5'

write_catalog
sed 's/version = "1.2.3"/version = "1.2.3-1"/' "${test_root}/tools.toml" > "${test_root}/tools.toml.tmp"
mv "${test_root}/tools.toml.tmp" "${test_root}/tools.toml"
write_fixture 1.3.0 "$recent_release" "1.2.9 $recent_release"
expect_report "non-numeric pin does not fail lookup" 0 \
  "alpha                tool           1.2.3-1      1.3.0" \
  "1d 12h  ** RECENT"
expect_absent "non-numeric pin is not a lookup failure" "LOOKUP FAILED"
expect_absent "non-numeric pin lists no intervening row" $'\n                                                 1.2.9'

write_catalog
write_fixture
sed "s|^github-tags example/epsilon 0.10.0 .*|github-tags example/epsilon 0.11.0 ${recent_release} 0.10.3 ${older_release} 0.10.0 ${older_release}|" \
  "$fixture" > "${fixture}.tmp"
mv "${fixture}.tmp" "$fixture"
cat > "$tags_fixture" << 'FIXTURE'
example/epsilon v0.9.0
example/epsilon v0.10.0
example/epsilon v0.10.0^{}
example/epsilon v0.10.3
example/epsilon v0.10.3^{}
example/epsilon v0.10.5
example/epsilon v0.10.5^{}
example/epsilon v0.11.0
example/epsilon v0.11.0^{}
FIXTURE
expect_report "failed tag date fails the target lookup" 1 \
  "epsilon              tool           0.10.0       0.11.0" \
  $'\n                                                 0.10.3' \
  "5d 12h  ** UPGRADEABLE" \
  "FAIL: failed release lookups (1)" \
  "epsilon: upgrade-target lookup failed at github-tags:example/epsilon"
expect_absent "failed tag lookup does not claim an upgrade target" "Upgradable pins"
expect_absent "failed tag lookup does not claim a cooldown hold" \
  "epsilon 0.10.0 -> 0.11.0 (1d 12h within cooldown)"

write_fixture
sed "s|^github example/delta 3.1.0 .*|github example/delta 3.3.0 ${recent_release} 3.2.0 ${older_release}|" \
  "$fixture" > "${fixture}.tmp"
mv "${fixture}.tmp" "$fixture"
status=0
output=$(PATH="${fake_bin}:$PATH" FAKE_RELEASES_LIST_FAIL=example/delta \
  bash "${test_root}/scripts/check-tool-updates.bash" 2>&1) ||
  status=$?
if [[ "$status" == 1 &&
  "$output" == *"FAIL: failed release lookups (1)"* &&
  "$output" == *"delta: upgrade-target lookup failed at github:example/delta"* &&
  "$output" == *"delta                tool           3.1.0        3.3.0"* &&
  "$output" != *"delta 3.1.0 -> 3.3.0"* &&
  "$output" != *"No action needed"* ]]; then
  printf 'ok   %s\n' "failed release list fails the target lookup"
else
  printf 'FAIL %s: exit %s\n%s\n' "failed release list fails the target lookup" "$status" "$output" >&2
  failures=$((failures + 1))
fi

write_fixture 1.3.0 "$older_release"
expect_report "differing pin past the cooldown can be upgraded" 1 \
  "5d 12h  ** UPGRADEABLE" \
  "Upgradable pins (1): newest release past its cooldown" \
  "alpha 1.2.3 -> 1.3.0"
expect_absent "upgradeable report has no recent flag" "** RECENT"

sed "s|^pypi beta 2.0.0 .*|pypi beta 2.1.0 ${mature_release}|" \
  "$fixture" > "${fixture}.tmp"
mv "${fixture}.tmp" "$fixture"
cat >> "${test_root}/tools.toml" << 'TOML'

[uv]
kind = "tool"
version = "0.13.0"
releases = "pypi:uv"
TOML
printf 'pypi uv 0.13.5 %s\n' "$mature_release" >> "$fixture"
status=0
output=$(PATH="${fake_bin}:$PATH" COOLDOWN_DAYS=10 \
  bash "${test_root}/scripts/check-tool-updates.bash" 2>&1) ||
  status=$?
if [[ "$status" == 0 &&
  "$output" == *"5d 12h  ** RECENT"* &&
  "$output" == *"Cooldowns: Python packages and uv 10 days; other tools 10 days"* &&
  "$output" == *"alpha 1.2.3 -> 1.3.0 (5d 12h within cooldown)"* &&
  "$output" == *"beta 2.0.0 -> 2.1.0 (8d 12h within cooldown)"* &&
  "$output" == *"uv 0.13.0 -> 0.13.5 (8d 12h within cooldown)"* ]]; then
  printf 'ok   %s\n' "cooldown window is configurable"
else
  printf 'FAIL %s: exit %s\n%s\n' "cooldown window is configurable" "$status" "$output" >&2
  failures=$((failures + 1))
fi

status=0
output=$(PATH="${fake_bin}:$PATH" COOLDOWN_DAYS=soon \
  bash "${test_root}/scripts/check-tool-updates.bash" 2>&1) ||
  status=$?
if [[ "$status" == 2 && "$output" == *"COOLDOWN_DAYS must be a non-negative integer: soon"* ]]; then
  printf 'ok   %s\n' "invalid cooldown window is a usage error"
else
  printf 'FAIL %s: exit %s\n%s\n' "invalid cooldown window is a usage error" "$status" "$output" >&2
  failures=$((failures + 1))
fi

write_catalog
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
  "beta                 python         2.0.0        LOOKUP FAILED" \
  $'\n\nFAIL: failed release lookups (1)' \
  "beta: no release found at pypi:beta"

write_fixture
cat >> "${test_root}/tools.toml" << 'TOML'

[zeta]
kind = "tool"
version = "1.0.0"
releases = "svn:zeta"
TOML
expect_report "unsupported release source fails the report" 1 \
  "zeta                 tool           1.0.0        INVALID RELEASE SOURCE" \
  "FAIL: invalid catalog entries (1)" \
  "zeta: unsupported release source svn:zeta"

write_catalog
write_fixture
cat >> "${test_root}/tools.toml" << 'TOML'

[mermaid-lint]
kind = "tool"
version = "0.35.0"
releases = "npm:@mermaid-lint/cli"
TOML
printf 'npm @mermaid-lint/cli 0.54.0 %s 0.53.1 %s\n' \
  "$recent_release" "$older_release" >> "$fixture"
expect_report "scoped npm lookup selects the mature upgrade target" 1 \
  "mermaid-lint         tool           0.35.0       0.54.0" \
  "mermaid-lint 0.35.0 -> 0.53.1 (latest 0.54.0 within cooldown)"
expect_absent "scoped npm lookup succeeds" "LOOKUP FAILED"

for source in npm:@scope npm:scope/name npm:@/name npm:@scope/ npm:@scope/name/extra; do
  write_catalog
  cat >> "${test_root}/tools.toml" << TOML

[zeta]
kind = "tool"
version = "1.0.0"
releases = "${source}"
TOML
  expect_report "invalid scoped npm source ${source}" 1 \
    "zeta: unsupported release source ${source}"
done

write_catalog
cat >> "${test_root}/tools.toml" << 'TOML'

[zeta]
kind = "tool"
version = "1.0.0"
TOML
expect_report "missing releases field fails the report" 1 \
  "zeta                 tool           1.0.0        INVALID CATALOG ENTRY" \
  "zeta: missing version or releases field"

for catalog_kind in missing invalid; do
  write_catalog
  if [[ "$catalog_kind" == missing ]]; then
    sed '/^kind = /d' "${test_root}/tools.toml" > "${test_root}/tools.toml.tmp"
  else
    sed 's/kind = "tool"/kind = "native"/' "${test_root}/tools.toml" > "${test_root}/tools.toml.tmp"
  fi
  mv "${test_root}/tools.toml.tmp" "${test_root}/tools.toml"
  expect_report "$catalog_kind kind fails the report" 1 "alpha: kind must be python or tool"
done

if ((failures > 0)); then
  printf '\n%s tool update test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nAll tool update tests passed\n'
