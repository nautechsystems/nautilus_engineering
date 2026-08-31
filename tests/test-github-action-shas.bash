#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECK_SCRIPT="${REPO_ROOT}/scripts/check-github-action-shas.sh"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-action-shas-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

action_file="${test_root}/action.yml"
output="${test_root}/output"
fake_bin="${test_root}/bin"
mkdir -p "$fake_bin"

tag_object_sha=1111111111111111111111111111111111111111
commit_sha=2222222222222222222222222222222222222222
mismatch_sha=3333333333333333333333333333333333333333

printf '%s\n' \
  '#!/usr/bin/env bash' \
  "if [[ \"\$1\" != \"ls-remote\" ]] ||" \
  "  [[ \"\$2\" != \"https://github.com/actions/checkout.git\" ]]; then" \
  '  exit 2' \
  'fi' \
  "printf \"%s\\t%s\\n\" \"$tag_object_sha\" \"refs/tags/v1.2.3\" \"$commit_sha\" \"refs/tags/v1.2.3^{}\"" \
  > "${fake_bin}/git"
chmod +x "${fake_bin}/git"

printf '# https://github.com/actions/checkout\nuses: actions/checkout@%s # v1.2.3\n' \
  "$commit_sha" > "$action_file"
PATH="${fake_bin}:${PATH}" bash "$CHECK_SCRIPT" "$action_file" > "$output"
grep -Fxq "Checking actions/checkout (v1.2.3): OK ($commit_sha)" "$output"

printf '# https://github.com/actions/checkout\nuses: actions/checkout/subpath@%s # v1.2.3\n' \
  "$commit_sha" > "$action_file"
PATH="${fake_bin}:${PATH}" bash "$CHECK_SCRIPT" "$action_file" > "$output"
grep -Fq "OK ($commit_sha)" "$output"

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

echo "All GitHub Action SHA tests passed"
