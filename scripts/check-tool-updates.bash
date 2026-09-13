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
# not change tools.toml. For each differing pin, the summary names the newest
# upstream release past the COOLDOWN_DAYS adoption cooldown (default 3 days)
# as that pin's upgrade target; a target can be older than the latest release
# when the latest release is still within the cooldown. A differing pin whose
# latest release is within the cooldown and has no newer release past it is a
# cooldown hold, which does not fail the check. A differing pin whose latest
# release is past the cooldown but not newer than the pin is a pin mismatch,
# which fails the check, as does a failed upgrade-target lookup. GitHub
# release targets consider the most recent 100 releases, and github-tags
# targets date each newer tag on demand. Exits 0 when every pin matches its
# latest upstream release or every differing pin is a cooldown hold, 1 when a
# pin has an upgrade target or a lookup fails, and 2 on a usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLS_TOML="${REPO_ROOT}/tools.toml"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"
COOLDOWN_DAYS="${COOLDOWN_DAYS:-3}"

if ! [[ "$COOLDOWN_DAYS" =~ ^[0-9]+$ ]]; then
  echo "Error: COOLDOWN_DAYS must be a non-negative integer: $COOLDOWN_DAYS" >&2
  exit 2
fi
RELEASE_SOURCE_PATTERN='^((crates|npm|pypi):[A-Za-z0-9][A-Za-z0-9._-]*|(github|github-tags):[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$'
JQ_EPOCH_DEF='def epoch: sub("\\+00:00$"; "Z") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;'

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
  local source=$1 pinned=$2 cutoff_epoch=$3
  local registry package latest_info latest published adoptable target_failed
  registry=${source%%:*}
  package=${source#*:}
  case "$registry" in
    crates)
      fetch_json "https://crates.io/api/v1/crates/${package}" |
        jq -r --argjson cutoff "$cutoff_epoch" '
          '"${JQ_EPOCH_DEF}"'
          .crate.max_stable_version as $latest
          | [$latest,
             ([.versions[] | select(.num == $latest) | .created_at][0] // ""),
             ([.versions[]
               | select(.yanked | not)
               | select(.num | test("^[0-9]+(\\.[0-9]+)*$"))
               | select(.created_at != null)
               | select((.created_at | epoch) <= $cutoff)]
              | max_by(.num | split(".") | map(tonumber))
              | .num // ""),
             ""]
            | join("|")
        '
      ;;
    github)
      latest_info=$(fetch_json "https://api.github.com/repos/${package}/releases/latest" |
        jq -r '[(.tag_name | sub("^v"; "")), (.published_at // .created_at // "")] | @tsv') ||
        return 1
      IFS="$tab" read -r latest published <<< "$latest_info"
      adoptable=""
      target_failed=""
      if ! adoptable=$(github_release_target "$package" "$pinned" "$latest" "$published" "$cutoff_epoch"); then
        adoptable=""
        target_failed=1
      fi
      printf '%s|%s|%s|%s\n' "$latest" "$published" "$adoptable" "$target_failed"
      ;;
    github-tags)
      github_tag_release "$package" "$pinned" "$cutoff_epoch"
      ;;
    npm)
      fetch_json "https://registry.npmjs.org/${package}" |
        jq -r --argjson cutoff "$cutoff_epoch" '
          '"${JQ_EPOCH_DEF}"'
          .["dist-tags"].latest as $latest
          | [$latest,
             (.time[$latest] // ""),
             ([.time | to_entries[]
               | select(.key | test("^[0-9]+(\\.[0-9]+)*$"))
               | select(.value != null)
               | select((.value | epoch) <= $cutoff)]
              | max_by(.key | split(".") | map(tonumber))
              | .key // ""),
             ""]
            | join("|")
        '
      ;;
    pypi)
      fetch_json "https://pypi.org/pypi/${package}/json" |
        jq -r --argjson cutoff "$cutoff_epoch" '
          '"${JQ_EPOCH_DEF}"'
          .info.version as $latest
          | [$latest,
             ([.urls[]? | .upload_time_iso_8601] | min // ""),
             ([.releases | to_entries[]
               | select(.key | test("^[0-9]+(\\.[0-9]+)*$"))
               | select(.value | length > 0)
               | select(((.value | map(.upload_time_iso_8601) | min) | epoch) <= $cutoff)]
              | max_by(.key | split(".") | map(tonumber))
              | .key // ""),
             ""]
            | join("|")
        '
      ;;
  esac
}

github_release_target() {
  local package=$1 pinned=$2 latest=$3 published=$4 cutoff_epoch=$5
  local latest_epoch
  [[ "$latest" == "$pinned" ]] && return 0
  latest_epoch=$(timestamp_epoch "$published") || return 0
  if ((latest_epoch <= cutoff_epoch)); then
    printf '%s\n' "$latest"
    return 0
  fi
  fetch_json "https://api.github.com/repos/${package}/releases?per_page=100" |
    jq -r --argjson cutoff "$cutoff_epoch" '
      '"${JQ_EPOCH_DEF}"'
      [.[]
        | select(.prerelease // false | not)
        | select(.tag_name | sub("^v"; "") | test("^[0-9]+(\\.[0-9]+)*$"))
        | select(((.published_at // .created_at // "") | epoch) <= $cutoff)]
      | max_by(.tag_name | sub("^v"; "") | split(".") | map(tonumber))
      | (.tag_name | sub("^v"; "")) // ""
    '
}

github_tag_release() {
  local package=$1 pinned=$2 cutoff_epoch=$3
  local refs versions latest published adoptable target_failed latest_epoch
  refs=$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags "https://github.com/${package}") || return 1
  versions=$(printf '%s\n' "$refs" | github_tag_versions)
  [[ -n "$versions" ]] || return 1
  latest=$(printf '%s\n' "$versions" | sed -n '1p')
  published=$(github_tag_published "$package" "$latest" "$refs") || return 1
  [[ -n "$published" ]] || return 1
  adoptable=""
  target_failed=""
  if [[ "$latest" != "$pinned" ]]; then
    if latest_epoch=$(timestamp_epoch "$published"); then
      if ((latest_epoch <= cutoff_epoch)); then
        adoptable=$latest
      elif ! adoptable=$(github_tags_target "$package" "$pinned" "$cutoff_epoch" "$refs" "$versions"); then
        adoptable=""
        target_failed=1
      fi
    fi
  fi
  printf '%s|%s|%s|%s\n' "$latest" "$published" "$adoptable" "$target_failed"
}

github_tag_versions() {
  sed -n 's|.*refs/tags/v\{0,1\}\([0-9][0-9.]*\)$|\1|p' |
    LC_ALL=C sort -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n |
    awk '!seen[$0]++' |
    awk '{ lines[NR] = $0 } END { for (i = NR; i >= 1; i--) print lines[i] }'
}

github_tag_published() {
  local package=$1 version=$2 refs=$3 tag object_sha peeled_sha
  tag=$(printf '%s\n' "$refs" | awk -v plain="$version" -v prefixed="v$version" '
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
    fetch_json "https://api.github.com/repos/${package}/git/tags/${object_sha}" |
      jq -r '.tagger.date // empty'
  else
    fetch_json "https://api.github.com/repos/${package}/commits/${object_sha}" |
      jq -r '.commit.committer.date // .commit.author.date // empty'
  fi
}

github_tags_target() {
  local package=$1 pinned=$2 cutoff_epoch=$3 refs=$4 versions=$5
  local version published epoch target=""
  while IFS= read -r version; do
    version_newer "$version" "$pinned" || break
    published=$(github_tag_published "$package" "$version" "$refs") || return 1
    epoch=$(timestamp_epoch "$published") || return 1
    if ((epoch <= cutoff_epoch)); then
      target=$version
      break
    fi
  done <<< "$versions"
  printf '%s\n' "$target"
}

version_newer() {
  local candidate=$1 baseline=$2 verdict
  # BEGIN-only: an END block would read and drain the caller's stdin
  verdict=$(awk -v a="$candidate" -v b="$baseline" 'BEGIN {
    na = split(a, ca, ".")
    nb = split(b, cb, ".")
    n = (na > nb) ? na : nb
    for (i = 1; i <= n; i++) {
      x = (i <= na) ? ca[i] + 0 : 0
      y = (i <= nb) ? cb[i] + 0 : 0
      if (x != y) {
        print (x > y) ? "newer" : ""
        exit
      }
    }
    print ""
  }')
  [[ "$verdict" == "newer" ]]
}

timestamp_epoch() {
  jq -ner --arg timestamp "$1" '
    $timestamp
    | sub("\\+00:00$"; "Z")
    | sub("\\.[0-9]+Z$"; "Z")
    | fromdateiso8601
    | floor
  ' 2> /dev/null
}

format_age() {
  local published=$1 now=$2 published_seconds age_seconds days hours
  published_seconds=$(timestamp_epoch "$published") || return 1
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
upgradeable_lines=()
hold_lines=()
mismatch_lines=()
color_red=""
color_orange=""
color_reset=""
if [[ -t 1 && -z "${NO_COLOR+x}" ]]; then
  color_red=$(printf '\033[0;31m')
  color_orange=$(printf '\033[38;5;208m')
  color_reset=$(printf '\033[0m')
fi
now=$(jq -nr 'now | floor')
cutoff_epoch=$((now - COOLDOWN_DAYS * 86400))
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
  if ! release=$(release_info "$source" "$version" "$cutoff_epoch"); then
    printf '%-20s %-12s LOOKUP FAILED\n' "$name" "$version"
    lookup_lines+=("${name}: no release found at ${source}")
    continue
  fi
  IFS='|' read -r latest published adoptable target_failed <<< "$release"
  if [[ -z "$latest" || -z "$published" ]] || ! age=$(format_age "$published" "$now"); then
    printf '%-20s %-12s LOOKUP FAILED\n' "$name" "$version"
    lookup_lines+=("${name}: no release time found at ${source}")
    continue
  fi
  if [[ -n "$target_failed" ]]; then
    lookup_lines+=("${name}: upgrade-target lookup failed at ${source}")
  fi
  released=${published%%.*}
  released=${released%Z}
  released=${released%+00:00}
  released=${released/T/ }
  latest_fresh=""
  if [[ "$age" == "future" ]]; then
    age_days=-1
  else
    age_days=${age%%d*}
  fi
  if [[ "$age" == "future" ]] || ((age_days < COOLDOWN_DAYS)); then
    latest_fresh=1
  fi
  flag=""
  if [[ "$latest" != "$version" && -z "$target_failed" ]]; then
    if [[ -n "$latest_fresh" ]]; then
      flag="  ** RECENT"
    else
      flag="  ** OUTDATED"
    fi
    if [[ -n "$adoptable" ]] && version_newer "$adoptable" "$version"; then
      summary_line="${name} ${version} -> ${adoptable}"
      if [[ "$adoptable" != "$latest" ]]; then
        if [[ -n "$latest_fresh" ]]; then
          summary_line="${summary_line} (latest ${latest} within cooldown)"
        else
          summary_line="${summary_line} (latest ${latest})"
        fi
      fi
      upgradeable_lines+=("$summary_line")
    elif [[ -n "$latest_fresh" ]]; then
      read -r age_inline <<< "$age"
      hold_lines+=("${name} ${version} -> ${latest} (${age_inline} within cooldown)")
    else
      mismatch_lines+=("${name} ${version} (latest ${latest} is not newer)")
    fi
  fi
  age_color=""
  age_reset=""
  if ((age_days == 0)); then
    age_color=$color_red
  elif ((age_days >= 0 && age_days < COOLDOWN_DAYS)); then
    age_color=$color_orange
  fi
  if [[ -n "$age_color" ]]; then
    age_reset=$color_reset
  fi
  printf '%-20s %-12s %-12s %-20s ' "$name" "$version" "$latest" "$released"
  printf '%s%s%s%s\n' "$age_color" "$age" "$age_reset" "$flag"
done <<< "$entries"

exit_code=0

if ((${#catalog_lines[@]} > 0)); then
  echo
  echo "FAIL: invalid catalog entries (${#catalog_lines[@]})"
  for line in "${catalog_lines[@]}"; do
    echo "  - ${line}"
  done
  echo "  Fix tools.toml; make check validates every releases field."
  exit_code=1
fi

if ((${#lookup_lines[@]} > 0)); then
  echo
  echo "FAIL: failed release lookups (${#lookup_lines[@]})"
  for line in "${lookup_lines[@]}"; do
    echo "  - ${line}"
  done
  echo "  Retry with the release registries reachable."
  exit_code=1
fi

if ((${#upgradeable_lines[@]} > 0)); then
  echo
  echo "Upgradable pins (${#upgradeable_lines[@]}): newest release past the ${COOLDOWN_DAYS}-day cooldown"
  for line in "${upgradeable_lines[@]}"; do
    echo "  - ${line}"
  done
  echo "  Update tools.toml here first; consumers adopt the reviewed commit."
  exit_code=1
fi

if ((${#mismatch_lines[@]} > 0)); then
  echo
  echo "Pin mismatches (${#mismatch_lines[@]}): latest upstream release is not newer than the pin"
  for line in "${mismatch_lines[@]}"; do
    echo "  - ${line}"
  done
  echo "  Check the pin and the upstream release history."
  exit_code=1
fi

if ((${#hold_lines[@]} > 0)); then
  echo
  echo "Cooldown holds (${#hold_lines[@]}): every newer release is within the ${COOLDOWN_DAYS}-day cooldown"
  for line in "${hold_lines[@]}"; do
    echo "  - ${line}"
  done
  echo "  No action needed until the cooldown passes."
fi

if ((exit_code == 0 && ${#hold_lines[@]} == 0)); then
  echo
  echo "All ${count} tool pin(s) match their latest upstream releases"
fi

exit "$exit_code"
