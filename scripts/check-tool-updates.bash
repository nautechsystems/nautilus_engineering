#!/usr/bin/env bash
# Report cataloged tool pins whose upstream has a newer release.
#
# Reads every tool table in the root tools.toml and queries the release source
# named by its `releases` field:
#
#     crates:NAME             crates.io latest stable version and publish time
#     github:OWNER/REPO       latest GitHub release tag and publish time
#     github-tags:OWNER/REPO  highest stable version tag and tag or commit time
#     npm:NAME                npm latest dist-tag and publish time
#     pypi:NAME               PyPI latest release and upload time
#
# Run on demand or through `make outdated`. This is a read-only report; it does
# not change tools.toml. Exits 0 when every pin matches its latest upstream
# release, 1 when a pin differs or a lookup fails, and 2 on a usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLS_TOML="${REPO_ROOT}/tools.toml"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"
RELEASE_SOURCE_PATTERN='^((crates|npm|pypi):[A-Za-z0-9][A-Za-z0-9._-]*|(github|github-tags):[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$'

for required in awk curl git jq; do
  command -v "$required" > /dev/null || {
    echo "Required command not on PATH: $required" >&2
    exit 2
  }
done

if [[ ! -f "$TOOLS_TOML" ]]; then
  echo "Error: shared tools catalog not found at $TOOLS_TOML" >&2
  exit 2
fi

entries=$(awk '
  function emit() { if (name != "") printf "%s %s %s\n", name, version, releases }
  /^\[[A-Za-z0-9._-]+\]$/ {
    emit()
    name = substr($0, 2, length($0) - 2)
    version = ""
    releases = ""
  }
  name != "" && /^version[[:space:]]*=/ {
    value = $0
    gsub(/.*=[[:space:]]*"/, "", value)
    gsub(/".*/, "", value)
    version = value
  }
  name != "" && /^releases[[:space:]]*=/ {
    value = $0
    gsub(/.*=[[:space:]]*"/, "", value)
    gsub(/".*/, "", value)
    releases = value
  }
  END { emit() }
' "$TOOLS_TOML")

if [[ -z "$entries" ]]; then
  echo "Error: no tool tables found in $TOOLS_TOML" >&2
  exit 2
fi

fetch_json() {
  curl -fsSL \
    --retry 3 \
    --retry-all-errors \
    --retry-max-time 60 \
    --max-time "$CURL_MAX_TIME" \
    -A "nautilus-engineering-tool-updates/1.0" \
    "$1"
}

release_info() {
  local source=$1 registry package
  registry=${source%%:*}
  package=${source#*:}
  case "$registry" in
    crates)
      fetch_json "https://crates.io/api/v1/crates/${package}" |
        jq -r '
          .crate.max_stable_version as $latest
          | [$latest, ([.versions[] | select(.num == $latest) | .created_at][0] // "")]
          | @tsv
        '
      ;;
    github)
      fetch_json "https://api.github.com/repos/${package}/releases/latest" |
        jq -r '[(.tag_name | sub("^v"; "")), (.published_at // .created_at // "")] | @tsv'
      ;;
    github-tags)
      github_tag_release "$package"
      ;;
    npm)
      fetch_json "https://registry.npmjs.org/${package}" |
        jq -r '
          .["dist-tags"].latest as $latest
          | [$latest, (.time[$latest] // "")]
          | @tsv
        '
      ;;
    pypi)
      fetch_json "https://pypi.org/pypi/${package}/json" |
        jq -r '
          .info.version as $latest
          | [$latest, ([.urls[]? | .upload_time_iso_8601] | min // "")]
          | @tsv
        '
      ;;
  esac
}

github_tag_release() {
  local package=$1 refs latest tag object_sha peeled_sha published
  refs=$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags "https://github.com/${package}")
  latest=$(printf '%s\n' "$refs" |
    sed -n 's|.*refs/tags/v\{0,1\}\([0-9][0-9.]*\)$|\1|p' |
    LC_ALL=C sort -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n |
    tail -n 1)
  [[ -n "$latest" ]] || return 1
  tag=$(printf '%s\n' "$refs" | awk -v plain="$latest" -v prefixed="v$latest" '
    $2 == "refs/tags/" prefixed { print prefixed; found=1; exit }
    $2 == "refs/tags/" plain { fallback=plain }
    END { if (!found && fallback != "") print fallback }
  ')
  [[ -n "$tag" ]] || return 1
  object_sha=$(printf '%s\n' "$refs" |
    awk -v ref="refs/tags/$tag" '$2 == ref { print $1; exit }')
  peeled_sha=$(printf '%s\n' "$refs" |
    awk -v ref="refs/tags/$tag^{}" '$2 == ref { print $1; exit }')
  [[ -n "$object_sha" ]] || return 1
  if [[ -n "$peeled_sha" ]]; then
    published=$(fetch_json "https://api.github.com/repos/${package}/git/tags/${object_sha}" |
      jq -r '.tagger.date // empty')
  else
    published=$(fetch_json "https://api.github.com/repos/${package}/commits/${object_sha}" |
      jq -r '.commit.committer.date // .commit.author.date // empty')
  fi
  [[ -n "$published" ]] || return 1
  printf '%s\t%s\n' "$latest" "$published"
}

format_age() {
  local published=$1 now=$2 published_seconds age_seconds days hours
  published_seconds=$(jq -ner --arg timestamp "$published" '
    $timestamp
    | sub("\\+00:00$"; "Z")
    | sub("\\.[0-9]+Z$"; "Z")
    | fromdateiso8601
    | floor
  ' 2> /dev/null) || return 1
  age_seconds=$((now - published_seconds))
  if ((age_seconds < 0)); then
    printf 'future'
    return
  fi
  days=$((age_seconds / 86400))
  hours=$(((age_seconds % 86400) / 3600))
  printf '%3dd %2dh' "$days" "$hours"
}

count=$(printf '%s\n' "$entries" | wc -l | tr -d '[:space:]')
echo "Checking ${count} cataloged tool pin(s) against upstream releases"
echo

printf '%-20s %-12s %-12s %-20s %s\n' "tool" "pinned" "latest" "released (UTC)" "age"
printf -- '-%.0s' {1..84}
printf '\n'

catalog_lines=()
lookup_lines=()
outdated_lines=()
color_red=""
color_orange=""
color_reset=""
if [[ -t 1 && -z "${NO_COLOR+x}" ]]; then
  color_red=$(printf '\033[0;31m')
  color_orange=$(printf '\033[38;5;208m')
  color_reset=$(printf '\033[0m')
fi
now=$(jq -nr 'now | floor')
tab=$(printf '\t')

while IFS=' ' read -r name version source; do
  [[ -z "$name" ]] && continue
  if [[ -z "$version" || -z "$source" ]]; then
    printf '%-20s %-12s INVALID CATALOG ENTRY\n' "$name" "$version"
    catalog_lines+=("${name}: missing version or releases field")
    continue
  fi
  if ! [[ "$source" =~ $RELEASE_SOURCE_PATTERN ]]; then
    printf '%-20s %-12s INVALID RELEASE SOURCE\n' "$name" "$version"
    catalog_lines+=("${name}: unsupported release source ${source}")
    continue
  fi
  if ! release=$(release_info "$source"); then
    printf '%-20s %-12s LOOKUP FAILED\n' "$name" "$version"
    lookup_lines+=("${name}: no release found at ${source}")
    continue
  fi
  IFS="$tab" read -r latest published <<< "$release"
  if [[ -z "$latest" || -z "$published" ]] || ! age=$(format_age "$published" "$now"); then
    printf '%-20s %-12s LOOKUP FAILED\n' "$name" "$version"
    lookup_lines+=("${name}: no release time found at ${source}")
    continue
  fi
  released=${published%%.*}
  released=${released%Z}
  released=${released%+00:00}
  released=${released/T/ }
  flag=""
  if [[ "$latest" != "$version" ]]; then
    flag="  ** OUTDATED"
    outdated_lines+=("${name} ${version} -> ${latest}")
  fi
  age_color=""
  age_reset=""
  case "$age" in
    *d*)
      age_days=${age%%d*}
      if ((age_days == 0)); then
        age_color=$color_red
      elif ((age_days < 3)); then
        age_color=$color_orange
      fi
      ;;
  esac
  if [[ -n "$age_color" ]]; then
    age_reset=$color_reset
  fi
  printf '%-20s %-12s %-12s %-20s ' "$name" "$version" "$latest" "$released"
  printf '%s%s%s%s\n' "$age_color" "$age" "$age_reset" "$flag"
done <<< "$entries"

echo

exit_code=0

if ((${#catalog_lines[@]} > 0)); then
  echo "FAIL: ${#catalog_lines[@]} catalog tool(s) have an invalid version or release source:"
  for line in "${catalog_lines[@]}"; do
    echo "  - ${line}"
  done
  echo "  Fix tools.toml; make check validates every releases field."
  exit_code=1
fi

if ((${#lookup_lines[@]} > 0)); then
  echo "FAIL: ${#lookup_lines[@]} release lookup(s) failed:"
  for line in "${lookup_lines[@]}"; do
    echo "  - ${line}"
  done
  echo "  Retry with the release registries reachable."
  exit_code=1
fi

if ((${#outdated_lines[@]} > 0)); then
  echo "${#outdated_lines[@]} tool pin(s) differ from the latest upstream release:"
  for line in "${outdated_lines[@]}"; do
    echo "  - ${line}"
  done
  echo "  Update tools.toml here first; consumers adopt the reviewed commit."
  exit_code=1
fi

if ((exit_code == 0)); then
  echo "All ${count} tool pin(s) match their latest upstream releases"
fi

exit "$exit_code"
