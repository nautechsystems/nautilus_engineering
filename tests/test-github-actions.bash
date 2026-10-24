#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECK_SCRIPT="${REPO_ROOT}/scripts/check-github-actions.sh"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-action-shas-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

action_file="${test_root}/action.yml"
output="${test_root}/output"
fake_bin="${test_root}/bin"
mkdir -p "$fake_bin"

tag_object_sha=1111111111111111111111111111111111111111
commit_sha=2222222222222222222222222222222222222222
mismatch_sha=3333333333333333333333333333333333333333

export FAKE_TAG_OBJECT_SHA="$tag_object_sha" FAKE_COMMIT_SHA="$commit_sha"
export FAKE_RELEASE_JSON="${test_root}/release.json"
export FAKE_CURL_ARGS="${test_root}/curl-args" FAKE_CURL_HEADERS="${test_root}/curl-headers"
export GITHUB_TOKEN=fixture-github-token
cat > "${fake_bin}/git" << 'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail
tag=${FAKE_TAG:-v1.2.3}
if [[ "$#" != 4 || "$1" != ls-remote ||
  "$2" != https://github.com/actions/checkout.git ||
  "$3" != "refs/tags/$tag" || "$4" != "refs/tags/$tag^{}" ]]; then
  exit 2
fi
if [[ "${FAKE_ANNOTATED_TAG:-1}" == 1 ]]; then
  printf '%s\t%s\n' "$FAKE_TAG_OBJECT_SHA" "refs/tags/$tag"
  printf '%s\t%s\n' "$FAKE_COMMIT_SHA" "refs/tags/$tag^{}"
else
  printf '%s\t%s\n' "$FAKE_COMMIT_SHA" "refs/tags/$tag"
fi
exit "${FAKE_GIT_STATUS:-0}"
FAKE_GIT
cat > "${fake_bin}/curl" << 'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$FAKE_CURL_ARGS"
cat > "$FAKE_CURL_HEADERS"
expected=(-fsSL --connect-timeout 10 --max-time 30 --header @-
  --header 'Accept: application/vnd.github+json'
  --header 'X-GitHub-Api-Version: 2022-11-28'
  "https://api.github.com/repos/actions/checkout/releases/tags/${FAKE_ENCODED_TAG:-v1.2.3}")
if [[ "$#" != "${#expected[@]}" ]]; then
  exit 2
fi
index=0
for argument in "$@"; do
  [[ "$argument" == "${expected[$index]}" ]] || exit 2
  index=$((index + 1))
done
cat "$FAKE_RELEASE_JSON"
exit "${FAKE_CURL_STATUS:-0}"
FAKE_CURL
cat > "${fake_bin}/date" << 'FAKE_DATE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 2 && "$1" == -u && "$2" == +%s ]] || exit 2
printf '%s\n' "${FAKE_CURRENT_EPOCH:-1792843200}"
exit "${FAKE_DATE_STATUS:-0}"
FAKE_DATE
chmod +x "${fake_bin}/git" "${fake_bin}/curl" "${fake_bin}/date"
export PATH="${fake_bin}:${PATH}"
printf '%s\n' '{"tag_name":"v1.2.3","draft":false,"published_at":"2026-10-10T12:00:00Z"}' \
  > "$FAKE_RELEASE_JSON"

printf '# https://github.com/actions/checkout\nuses: actions/checkout@%s # v1.2.3\n' \
  "$commit_sha" > "$action_file"
PATH="${fake_bin}:${PATH}" bash "$CHECK_SCRIPT" "$action_file" > "$output"
grep -Fxq "Checking actions/checkout (v1.2.3): OK ($commit_sha; release published at least 14 complete days ago)" "$output"
[[ "$(< "$FAKE_CURL_HEADERS")" == 'Authorization: Bearer fixture-github-token' ]]
if grep -Fq "$GITHUB_TOKEN" "$FAKE_CURL_ARGS"; then
  echo 'GitHub token must not appear in curl arguments' >&2
  exit 1
fi

printf '# https://github.com/actions/checkout\nuses: actions/checkout/subpath@%s # v1.2.3\n' \
  "$commit_sha" > "$action_file"
PATH="${fake_bin}:${PATH}" bash "$CHECK_SCRIPT" "$action_file" > "$output"
grep -Fq "OK ($commit_sha;" "$output"

for annotated in 0 1; do
  for publication in 2026-10-10T12:00:01Z 2026-10-10T12:00:00Z 2026-10-10T11:59:59Z 2026-10-24T12:00:01Z; do
    printf '{"tag_name":"v1.2.3","draft":false,"published_at":"%s"}\n' "$publication" \
      > "$FAKE_RELEASE_JSON"
    status=0
    output_text=$(FAKE_ANNOTATED_TAG="$annotated" bash "$CHECK_SCRIPT" "$action_file" 2>&1) || status=$?
    case "$publication" in
      2026-10-10T12:00:01Z | 2026-10-24T12:00:01Z)
        expected_status=1
        expected_result='FAILED (release is less than 14 complete days old)'
        ;;
      *)
        expected_status=0
        expected_result="OK ($commit_sha; release published at least 14 complete days ago)"
        ;;
    esac
    expected_output="Checking actions/checkout/subpath (v1.2.3): $expected_result"
    if [[ "$status" != "$expected_status" || "$output_text" != "$expected_output" ]]; then
      printf 'FAIL release boundary %s (annotated=%s): exit %s\n%s\n' \
        "$publication" "$annotated" "$status" "$output_text" >&2
      exit 1
    fi
  done
done

for metadata in \
  '{}' \
  '{"tag_name":"v1.2.3","draft":false,"created_at":"2020-01-01T00:00:00Z"}' \
  '{"tag_name":"v1.2.3","draft":false,"published_at":null}' \
  '{"tag_name":"v1.2.3","draft":false,"published_at":""}' \
  '{"tag_name":"v1.2.3","draft":false,"published_at":1791633600}' \
  '{"tag_name":"v1.2.3","draft":false,"published_at":"invalid"}' \
  '{"tag_name":"v1.2.3","draft":false,"published_at":"2026-02-30T12:00:00Z"}' \
  '{"tag_name":"v1.2.3","draft":true,"published_at":"2026-10-10T12:00:00Z"}' \
  '{"tag_name":"v9.9.9","draft":false,"published_at":"2026-10-10T12:00:00Z"}' \
  'not-json' \
  ''; do
  printf '%s\n' "$metadata" > "$FAKE_RELEASE_JSON"
  status=0
  output_text=$(bash "$CHECK_SCRIPT" "$action_file" 2>&1) || status=$?
  if [[ "$status" != 1 || "$output_text" != 'Checking actions/checkout/subpath (v1.2.3): FAILED (missing or invalid release published_at metadata)' ]]; then
    printf 'FAIL invalid release metadata %s: exit %s\n%s\n' "$metadata" "$status" "$output_text" >&2
    exit 1
  fi
done

printf '%s\n' '{"tag_name":"v1.2.3","draft":false,"published_at":"2026-10-10T12:00:00Z"}' \
  > "$FAKE_RELEASE_JSON"
for failure in curl git; do
  status=0
  if [[ "$failure" == curl ]]; then
    output_text=$(FAKE_CURL_STATUS=22 bash "$CHECK_SCRIPT" "$action_file" 2>&1) || status=$?
    expected_result='release lookup failed'
  else
    output_text=$(FAKE_GIT_STATUS=128 bash "$CHECK_SCRIPT" "$action_file" 2>&1) || status=$?
    expected_result='tag not found or repository inaccessible'
  fi
  if [[ "$status" != 1 || "$output_text" != "Checking actions/checkout/subpath (v1.2.3): FAILED ($expected_result)" ]]; then
    printf 'FAIL %s lookup failure: exit %s\n%s\n' "$failure" "$status" "$output_text" >&2
    exit 1
  fi
done

for clock in invalid -1; do
  status=0
  output_text=$(FAKE_CURRENT_EPOCH="$clock" bash "$CHECK_SCRIPT" "$action_file" 2>&1) || status=$?
  [[ "$status" == 2 && "$output_text" == 'Could not read the current UTC timestamp' ]]
done
status=0
output_text=$(FAKE_DATE_STATUS=1 bash "$CHECK_SCRIPT" "$action_file" 2>&1) || status=$?
[[ "$status" == 2 && "$output_text" == 'Could not read the current UTC timestamp' ]]

GITHUB_TOKEN='' bash "$CHECK_SCRIPT" "$action_file" > "$output"
[[ ! -s "$FAKE_CURL_HEADERS" ]]

printf '# https://github.com/actions/checkout\nuses: actions/checkout@%s # releases/v1.2.3\n' \
  "$commit_sha" > "$action_file"
printf '%s\n' '{"tag_name":"releases/v1.2.3","draft":false,"published_at":"2026-10-10T12:00:00Z"}' \
  > "$FAKE_RELEASE_JSON"
FAKE_TAG=releases/v1.2.3 FAKE_ENCODED_TAG=releases%2Fv1.2.3 \
  bash "$CHECK_SCRIPT" "$action_file" > "$output"
grep -Fxq "Checking actions/checkout (releases/v1.2.3): OK ($commit_sha; release published at least 14 complete days ago)" "$output"
printf '%s\n' '{"tag_name":"v1.2.3","draft":false,"published_at":"2026-10-10T12:00:00Z"}' \
  > "$FAKE_RELEASE_JSON"

real_bash=$(command -v bash)
for missing in curl jq; do
  dependency_bin="${test_root}/without-$missing"
  mkdir "$dependency_bin"
  for required in awk grep sed sort mktemp rm git date curl jq; do
    if [[ "$required" != "$missing" ]]; then
      ln -s "$(command -v "$required")" "${dependency_bin}/$required"
    fi
  done
  status=0
  output_text=$(PATH="$dependency_bin" "$real_bash" "$CHECK_SCRIPT" "$action_file" 2>&1) || status=$?
  if [[ "$status" != 2 || "$output_text" != "Required command not on PATH: $missing (install it before checking Action releases)" ]]; then
    printf 'FAIL missing dependency %s: exit %s\n%s\n' "$missing" "$status" "$output_text" >&2
    exit 1
  fi
done

printf '# https://github.com/actions/checkout\nuses: actions/checkout@%s # v1.2.3\n' \
  "$mismatch_sha" > "$action_file"
if PATH="${fake_bin}:${PATH}" bash "$CHECK_SCRIPT" "$action_file" > "$output"; then
  echo "Expected a tag commit mismatch to fail" >&2
  exit 1
fi
grep -Fq "MISMATCH (expected: $mismatch_sha, got: $commit_sha)" "$output"

printf '# https://github.com/actions/checkout\nuses: actions/checkout@%s\n' \
  "$commit_sha" > "$action_file"
if bash "$CHECK_SCRIPT" "$action_file" > "$output"; then
  echo "Expected a missing tag comment to fail" >&2
  exit 1
fi
grep -Fq "FAILED (missing '# <tag>' comment)" "$output"

printf '# https://github.com/actions/checkout\nuses: actions/checkout@%s #  \n' \
  "$commit_sha" > "$action_file"
if bash "$CHECK_SCRIPT" "$action_file" > "$output"; then
  echo "Expected an empty tag comment to fail" >&2
  exit 1
fi
grep -Fq "FAILED (missing '# <tag>' comment)" "$output"

printf 'uses: actions/checkout@%s # v1.2.3\n' "$commit_sha" > "$action_file"
if PATH="${fake_bin}:${PATH}" bash "$CHECK_SCRIPT" "$action_file" > "$output"; then
  echo "Expected a missing source comment to fail" >&2
  exit 1
fi
grep -Fq \
  "FAILED (expected source comment # https://github.com/actions/checkout immediately above)" \
  "$output"

printf '# https://github.com/actions/cache\nuses: actions/checkout@%s # v1.2.3\n' \
  "$commit_sha" > "$action_file"
if PATH="${fake_bin}:${PATH}" bash "$CHECK_SCRIPT" "$action_file" > "$output"; then
  echo "Expected an incorrect source comment to fail" >&2
  exit 1
fi
grep -Fq \
  "FAILED (expected source comment # https://github.com/actions/checkout immediately above)" \
  "$output"

printf '# https://github.com/actions/checkout\n- name: Checkout\nuses: actions/checkout@%s # v1.2.3\n' \
  "$commit_sha" > "$action_file"
if PATH="${fake_bin}:${PATH}" bash "$CHECK_SCRIPT" "$action_file" > "$output"; then
  echo "Expected a displaced source comment to fail" >&2
  exit 1
fi
grep -Fq \
  "FAILED (expected source comment # https://github.com/actions/checkout immediately above)" \
  "$output"

printf '%s\n' \
  '# https://github.com/actions/checkout' \
  'uses: actions/checkout@v7 # v7.0.0' \
  > "$action_file"
if bash "$CHECK_SCRIPT" "$action_file" > "$output"; then
  echo "Expected a tag action ref to fail" >&2
  exit 1
fi
grep -Fq "FAILED (expected full 40-character commit SHA): actions/checkout@v7" "$output"

printf '%s\n' \
  '# https://github.com/actions/checkout' \
  'uses: actions/checkout@222222222222 # v1.2.3' \
  > "$action_file"
if bash "$CHECK_SCRIPT" "$action_file" > "$output"; then
  echo "Expected a short action SHA to fail" >&2
  exit 1
fi
grep -Fq \
  "FAILED (expected full 40-character commit SHA): actions/checkout@222222222222" \
  "$output"

printf '%s\n' \
  '# https://github.com/actions/checkout' \
  'uses: actions/checkout # v1.2.3' \
  > "$action_file"
if bash "$CHECK_SCRIPT" "$action_file" > "$output"; then
  echo "Expected an action ref without an at-sign to fail" >&2
  exit 1
fi
grep -Fq "FAILED (expected full 40-character commit SHA): actions/checkout" "$output"

printf '%s\n' 'uses: ./.github/actions/common-setup' > "$action_file"
bash "$CHECK_SCRIPT" "$action_file" > "$output"
grep -Fq "No GitHub Action SHAs found." "$output"

for reference in '$/.github/actions/common-setup' '$/.github/workflows/build.yml'; do
  printf 'uses: %s\n' "$reference" > "$action_file"
  status=0
  output_text=$(PATH="${fake_bin}:${PATH}" bash "$CHECK_SCRIPT" "$action_file" 2>&1) || status=$?
  if [[ "$status" != 0 || "$output_text" != "No GitHub Action SHAs found." ]]; then
    printf 'FAIL self-repository reference %s: exit %s\n%s\n' \
      "$reference" "$status" "$output_text" >&2
    exit 1
  fi
done

printf '%s\n' 'uses: docker://alpine:3.22' > "$action_file"
bash "$CHECK_SCRIPT" "$action_file" > "$output"
grep -Fq "No GitHub Action SHAs found." "$output"

if bash "$CHECK_SCRIPT" > "$output" 2>&1; then
  echo "Expected a missing action-file argument to fail" >&2
  exit 1
fi
grep -Fq "Usage:" "$output"

missing_file="${test_root}/missing-action.yml"
status=0
output_text=$(bash "$CHECK_SCRIPT" "$missing_file" 2>&1) || status=$?
if [[ "$status" != 2 ||
  "$output_text" != "Action file is not a readable regular file: $missing_file" ]]; then
  printf 'FAIL missing action file: exit %s\n%s\n' "$status" "$output_text" >&2
  exit 1
fi

mktemp_bin="${test_root}/mktemp-bin"
mktemp_state="${test_root}/mktemp-state"
mktemp_log="${test_root}/mktemp.log"
mkdir "$mktemp_bin"
cat > "${mktemp_bin}/mktemp" << 'FAKE_MKTEMP'
#!/usr/bin/env bash
set -euo pipefail

count=0
if [[ -f "${FAKE_MKTEMP_STATE:?}" ]]; then
  count=$(< "$FAKE_MKTEMP_STATE")
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_MKTEMP_STATE"
if [[ "$count" == 2 ]]; then
  exit 1
fi

path=$("${REAL_MKTEMP:?}" "$@")
printf '%s\n' "$path" >> "${FAKE_MKTEMP_LOG:?}"
printf '%s\n' "$path"
FAKE_MKTEMP
chmod +x "${mktemp_bin}/mktemp"

printf '# https://github.com/actions/checkout\nuses: actions/checkout@%s # v1.2.3\n' \
  "$commit_sha" > "$action_file"
status=0
output_text=$(FAKE_MKTEMP_LOG="$mktemp_log" \
  FAKE_MKTEMP_STATE="$mktemp_state" \
  REAL_MKTEMP="$(command -v mktemp)" \
  PATH="${mktemp_bin}:${PATH}" \
  bash "$CHECK_SCRIPT" "$action_file" 2>&1) || status=$?
first_temp=$(< "$mktemp_log")
if [[ "$status" != 2 ||
  "$output_text" != "Could not create the temporary action failure file" ||
  -e "$first_temp" ]]; then
  printf 'FAIL second mktemp failure: exit %s, first temp %s\n%s\n' \
    "$status" "$first_temp" "$output_text" >&2
  exit 1
fi

pipeline_bin="${test_root}/pipeline-bin"
pipeline_tmp="${test_root}/pipeline-tmp"
mkdir "$pipeline_bin" "$pipeline_tmp"
cat > "${pipeline_bin}/sort" << 'FAKE_SORT'
#!/usr/bin/env bash
cat > /dev/null
exit 3
FAKE_SORT
chmod +x "${pipeline_bin}/sort"

status=0
output_text=$(TMPDIR="$pipeline_tmp" PATH="${pipeline_bin}:${PATH}" \
  bash "$CHECK_SCRIPT" "$action_file" 2>&1) || status=$?
remaining_temp=$(find "$pipeline_tmp" -type f -print -quit)
if [[ "$status" != 2 ||
  "$output_text" != "Could not collect GitHub Action references" ||
  -n "$remaining_temp" ]]; then
  printf 'FAIL pipeline dependency failure: exit %s, remaining temp %s\n%s\n' \
    "$status" "${remaining_temp:-none}" "$output_text" >&2
  exit 1
fi

echo "All GitHub Actions tests passed"
