#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECK_SCRIPT="${REPO_ROOT}/scripts/check-markdown-tables.py"
CI_WORKFLOW="${REPO_ROOT}/.github/workflows/ci.yaml"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-markdown-tables-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

table_file="${test_root}/table.md"
fenced_file="${test_root}/fenced.md"
expected_file="${test_root}/expected.md"
output_file="${test_root}/output"

cat > "$table_file" << 'MARKDOWN'
# Tables

|Name|Count|
|---|---:|
|Alpha|  7|
|Long name|  42|

| Symbol | Note |
| :---: | --- |
|  𐐷  | A \| B |
MARKDOWN

cat > "$expected_file" << 'MARKDOWN'
# Tables

| Name      | Count |
| --------- | ----: |
| Alpha     |     7 |
| Long name |    42 |

| Symbol | Note   |
| :----: | ------ |
|   𐐷   | A \| B |
MARKDOWN

cat > "$fenced_file" << 'MARKDOWN'
```markdown
|Name|Count|
|---|---:|
|Alpha|7|
```

| This block has mismatched cells |
| --- | --- |
MARKDOWN

status=0
python3 -B "$CHECK_SCRIPT" "$table_file" "$fenced_file" > "$output_file" || status=$?
if [[ "$status" != 1 ]] ||
  ! grep -Fq "table.md: normalized table column widths" "$output_file" ||
  grep -Fq "${fenced_file}:" "$output_file" ||
  ! diff -u "$expected_file" "$table_file"; then
  printf 'FAIL normalization: exit %s\n' "$status" >&2
  cat "$output_file" >&2
  exit 1
fi

fenced_before=$(git hash-object "$fenced_file")
status=0
python3 -B "$CHECK_SCRIPT" "$table_file" "$fenced_file" > "$output_file" || status=$?
fenced_after=$(git hash-object "$fenced_file")
if [[ "$status" != 0 || -s "$output_file" || "$fenced_before" != "$fenced_after" ]]; then
  printf 'FAIL idempotence or ignored blocks: exit %s\n' "$status" >&2
  cat "$output_file" >&2
  exit 1
fi

if ! grep -Fq \
  "python3 -B scripts/check-markdown-tables.py \"\${markdown_files[@]}\"" \
  "$CI_WORKFLOW"; then
  printf 'FAIL CI does not run the Markdown table check\n' >&2
  exit 1
fi

printf 'All Markdown table tests passed\n'
