#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYNC_SCRIPT="${REPO_ROOT}/sync/sync.bash"
SYNC_CHECK="${REPO_ROOT}/sync/check-synced-files.bash"

for required in awk git python3; do
  command -v "$required" > /dev/null || {
    echo "Required test command not on PATH: $required" >&2
    exit 1
  }
done

test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-sync-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
source_repo="${test_root}/source"
consumer="${test_root}/consumer"
mkdir -p "${source_repo}/config" "${source_repo}/sync" "$consumer"

cat > "${source_repo}/config/base.txt" << 'TEXT'
committed content
TEXT
cp "$SYNC_CHECK" "${source_repo}/sync/check-synced-files.bash"
chmod +x "${source_repo}/sync/check-synced-files.bash"
cat > "${source_repo}/sync/manifest.toml" << 'TOML'
version = 1
repository = "https://github.com/nautechsystems/nautilus_engineering"
lock_file = ".nautilus-engineering.lock"
marker_file = ".nautilus-engineering.syncing"

[[artifact]]
id = "base-config"
source = "config/base.txt"
target = "config/base.txt"
executable = false
profiles = ["base"]

[[artifact]]
id = "sync-check"
source = "sync/check-synced-files.bash"
target = "scripts/check-nautilus-engineering-sync.bash"
executable = true
profiles = ["sync"]
TOML

git -C "$source_repo" init --quiet
git -C "$source_repo" config user.email test@example.com
git -C "$source_repo" config user.name Test
git -C "$source_repo" config commit.gpgsign false
git -C "$source_repo" add -A
git -C "$source_repo" update-index --chmod=+x sync/check-synced-files.bash
git -C "$source_repo" commit --quiet -m source
source_revision=$(git -C "$source_repo" rev-parse HEAD)
printf 'uncommitted content\n' > "${source_repo}/config/base.txt"

git -C "$consumer" init --quiet
git -C "$consumer" config core.filemode true

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    worktree_success="All 2 synced file contents match the lock; executable modes were not checked"
    ;;
  *) worktree_success="All 2 synced files match the lock" ;;
esac

failures=0

status=0
output=$(bash "$SYNC_SCRIPT" --source "$source_repo" list) || status=$?
if [[ "$status" == 0 && "$output" == *"base-config"* && "$output" == *"sync-check"* ]] &&
  grep -Eq '^  base-config +config/base.txt +base$' <<< "$output" &&
  grep -Eq '^  sync-check +scripts/check-nautilus-engineering-sync.bash +sync$' <<< "$output"; then
  printf 'ok   list reports committed profiles and artifacts\n'
else
  printf 'FAIL list: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

status=0
output=$(bash "$SYNC_SCRIPT" --source "$source_repo" vendor \
  --consumer "$consumer" \
  --profile base \
  --profile sync \
  --target base-config=shared/base.txt) || status=$?
if [[ "$status" == 0 && "$output" == *"Vendored 2 artifact(s)"* ]] &&
  [[ $(< "${consumer}/shared/base.txt") == "committed content" ]] &&
  [[ -x "${consumer}/scripts/check-nautilus-engineering-sync.bash" ]] &&
  grep -Fq "revision = \"${source_revision}\"" "${consumer}/.nautilus-engineering.lock"; then
  printf 'ok   vendor uses committed content and records revision, target, and mode\n'
else
  printf 'FAIL vendor: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

status=0
output=$(cd "$consumer" && bash scripts/check-nautilus-engineering-sync.bash) || status=$?
if [[ "$status" == 0 && "$output" == *"$worktree_success"* ]]; then
  printf 'ok   worktree checker accepts exact vendored files\n'
else
  printf 'FAIL worktree check: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

mkdir "${consumer}/.nautilus-engineering.sync-lock"
status=0
output=$(cd "$consumer" && bash scripts/check-nautilus-engineering-sync.bash 2>&1) || status=$?
if [[ "$status" == 1 && "$output" == *"sync is active or left an incomplete process lock"* ]]; then
  printf 'ok   checker rejects an active or abandoned process lock\n'
else
  printf 'FAIL process lock check: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi
rmdir "${consumer}/.nautilus-engineering.sync-lock"

git -C "$consumer" add -A
git -C "$consumer" update-index --chmod=+x scripts/check-nautilus-engineering-sync.bash
status=0
output=$(cd "$consumer" && bash scripts/check-nautilus-engineering-sync.bash --staged) || status=$?
if [[ "$status" == 0 && "$output" == *"All 2 synced files match the lock"* ]]; then
  printf 'ok   staged checker accepts exact content and modes\n'
else
  printf 'FAIL staged check: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

printf 'worktree drift\n' > "${consumer}/shared/base.txt"
worktree_status=0
staged_status=0
worktree_output=$(cd "$consumer" && bash scripts/check-nautilus-engineering-sync.bash 2>&1) ||
  worktree_status=$?
staged_output=$(cd "$consumer" && bash scripts/check-nautilus-engineering-sync.bash --staged) ||
  staged_status=$?
if [[ "$worktree_status" == 1 && "$worktree_output" == *"content differs"* &&
  "$staged_status" == 0 ]]; then
  printf 'ok   worktree and staged checks inspect their named state\n'
else
  printf 'FAIL state-specific drift checks: worktree %s, staged %s\n%s\n%s\n' \
    "$worktree_status" "$staged_status" "$worktree_output" "$staged_output" >&2
  failures=$((failures + 1))
fi

git -C "$consumer" add shared/base.txt
status=0
output=$(cd "$consumer" && bash scripts/check-nautilus-engineering-sync.bash --staged 2>&1) || status=$?
if [[ "$status" == 1 && "$output" == *"content differs"* ]]; then
  printf 'ok   staged checker rejects staged content drift\n'
else
  printf 'FAIL staged content drift: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

bash "$SYNC_SCRIPT" --source "$source_repo" vendor \
  --consumer "$consumer" \
  --profile base \
  --profile sync \
  --target base-config=shared/base.txt > /dev/null
git -C "$consumer" add -A
git -C "$consumer" update-index --chmod=-x scripts/check-nautilus-engineering-sync.bash
status=0
output=$(cd "$consumer" && bash scripts/check-nautilus-engineering-sync.bash --staged 2>&1) || status=$?
if [[ "$status" == 1 && "$output" == *"staged mode is 100644, expected 100755"* ]]; then
  printf 'ok   staged checker rejects executable-mode drift\n'
else
  printf 'FAIL staged mode drift: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

status=0
output=$(bash "$SYNC_SCRIPT" --source "$source_repo" vendor --consumer "$consumer" 2>&1) || status=$?
if [[ "$status" == 2 && "$output" == *"select at least one"* &&
  ! -e "${consumer}/.nautilus-engineering.syncing" ]]; then
  printf 'ok   empty selection fails before starting a transaction\n'
else
  printf 'FAIL empty selection: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

reserved_status=0
git_status=0
case_status=0
parent_status=0
windows_status=0
reserved_output=$(bash "$SYNC_SCRIPT" --source "$source_repo" vendor \
  --consumer "$consumer" --artifact base-config \
  --target base-config=.nautilus-engineering.lock 2>&1) || reserved_status=$?
git_output=$(bash "$SYNC_SCRIPT" --source "$source_repo" vendor \
  --consumer "$consumer" --artifact base-config \
  --target base-config=.git/config 2>&1) || git_status=$?
case_output=$(bash "$SYNC_SCRIPT" --source "$source_repo" vendor \
  --consumer "$consumer" --artifact base-config --artifact sync-check \
  --target base-config=shared/File --target sync-check=shared/file 2>&1) || case_status=$?
parent_output=$(bash "$SYNC_SCRIPT" --source "$source_repo" vendor \
  --consumer "$consumer" --artifact base-config --artifact sync-check \
  --target base-config=shared --target sync-check=shared/file 2>&1) || parent_status=$?
windows_output=$(bash "$SYNC_SCRIPT" --source "$source_repo" vendor \
  --consumer "$consumer" --artifact base-config \
  --target base-config=CON.txt 2>&1) || windows_status=$?
if [[ "$reserved_status" == 2 && "$reserved_output" == *"overlaps reserved path"* &&
  "$git_status" == 2 && "$git_output" == *"reserved path component"* &&
  "$case_status" == 2 && "$case_output" == *"targets overlap"* &&
  "$parent_status" == 2 && "$parent_output" == *"targets overlap"* &&
  "$windows_status" == 2 && "$windows_output" == *"reserved path component"* ]] &&
  [[ ! -e "${consumer}/.nautilus-engineering.syncing" ]]; then
  printf 'ok   unsafe, reserved, colliding, and aliased targets fail before replacement\n'
else
  printf 'FAIL target validation: %s %s %s %s %s\n%s\n%s\n%s\n%s\n%s\n' \
    "$reserved_status" "$git_status" "$case_status" "$parent_status" "$windows_status" \
    "$reserved_output" "$git_output" "$case_output" "$parent_output" "$windows_output" >&2
  failures=$((failures + 1))
fi

lock_backup="${test_root}/consumer.lock"
cp "${consumer}/.nautilus-engineering.lock" "$lock_backup"
awk '$1 != "profiles"' "$lock_backup" > "${consumer}/.nautilus-engineering.lock"
missing_profiles_status=0
missing_profiles_output=$(cd "$consumer" &&
  bash scripts/check-nautilus-engineering-sync.bash 2>&1) || missing_profiles_status=$?
awk '{ if ($1 == "path" && !changed) { print "path = \"shared/base.txt"; changed=1; next } print }' \
  "$lock_backup" > "${consumer}/.nautilus-engineering.lock"
quote_status=0
quote_output=$(cd "$consumer" &&
  bash scripts/check-nautilus-engineering-sync.bash 2>&1) || quote_status=$?
cp "$lock_backup" "${consumer}/.nautilus-engineering.lock"
printf 'unexpected = true\n' >> "${consumer}/.nautilus-engineering.lock"
unknown_status=0
unknown_output=$(cd "$consumer" &&
  bash scripts/check-nautilus-engineering-sync.bash 2>&1) || unknown_status=$?
awk '{ if ($1 == "path" && !changed) { print "path = \".nautilus-engineering.lock\""; changed=1; next } print }' \
  "$lock_backup" > "${consumer}/.nautilus-engineering.lock"
reserved_entry_status=0
reserved_entry_output=$(cd "$consumer" &&
  bash scripts/check-nautilus-engineering-sync.bash 2>&1) || reserved_entry_status=$?
if [[ "$missing_profiles_status" == 2 && "$missing_profiles_output" == *"invalid structure"* &&
  "$quote_status" == 2 && "$quote_output" == *"invalid structure"* &&
  "$unknown_status" == 2 && "$unknown_output" == *"invalid structure"* &&
  "$reserved_entry_status" == 2 && "$reserved_entry_output" == *"Invalid sync lock entry"* ]]; then
  printf 'ok   checker rejects malformed fields and reserved managed paths\n'
else
  printf 'FAIL malformed lock checks: %s %s %s %s\n%s\n%s\n%s\n%s\n' \
    "$missing_profiles_status" "$quote_status" "$unknown_status" "$reserved_entry_status" \
    "$missing_profiles_output" "$quote_output" "$unknown_output" "$reserved_entry_output" >&2
  failures=$((failures + 1))
fi

status=0
output=$(bash "$SYNC_SCRIPT" --source "$source_repo" vendor \
  --consumer "$consumer" --profile base 2>&1) || status=$?
if [[ "$status" == 2 && "$output" == *"existing sync lock contains a reserved path"* &&
  ! -e "${consumer}/.nautilus-engineering.syncing" ]]; then
  printf 'ok   vendor rejects a malformed prior lock before replacement\n'
else
  printf 'FAIL malformed prior lock: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi
cp "$lock_backup" "${consumer}/.nautilus-engineering.lock"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) ;;
  *)
    symlink_consumer="${test_root}/symlink-consumer"
    external="${test_root}/external"
    mkdir -p "${symlink_consumer}/restored" "$external"
    git -C "$symlink_consumer" init --quiet
    ln -s "$external" "${symlink_consumer}/shared"
    printf 'prior content\n' > "${symlink_consumer}/restored/base.txt"
    status=0
    output=$(bash "$SYNC_SCRIPT" --source "$source_repo" vendor \
      --consumer "$symlink_consumer" \
      --artifact base-config --artifact sync-check \
      --target base-config=restored/base.txt \
      --target sync-check=shared/check.bash 2>&1) || status=$?
    if [[ "$status" == 2 && "$output" == *"traverses a symlink"* ]] &&
      [[ $(< "${symlink_consumer}/restored/base.txt") == "prior content" ]] &&
      [[ ! -e "${symlink_consumer}/.nautilus-engineering.syncing" ]] &&
      [[ ! -e "${external}/check.bash" ]] &&
      ! find "$symlink_consumer" -maxdepth 1 -name '.nautilus-engineering.tmp.*' | grep -q .; then
      printf 'ok   replacement failure restores prior files and clears transaction state\n'
    else
      printf 'FAIL symlink target: exit %s\n%s\n' "$status" "$output" >&2
      failures=$((failures + 1))
    fi

    check_consumer="${test_root}/symlink-check-consumer"
    check_external="${test_root}/check-external"
    mkdir -p "$check_consumer" "$check_external"
    git -C "$check_consumer" init --quiet
    bash "$SYNC_SCRIPT" --source "$source_repo" vendor \
      --consumer "$check_consumer" --profile base --target base-config=shared/base.txt > /dev/null
    mv "${check_consumer}/shared" "${check_external}/shared"
    ln -s "${check_external}/shared" "${check_consumer}/shared"
    status=0
    output=$(cd "$check_consumer" &&
      bash ../source/sync/check-synced-files.bash 2>&1) || status=$?
    if [[ "$status" == 1 && "$output" == *"file is missing, a symlink, or not regular"* ]]; then
      printf 'ok   worktree checker rejects a managed path through a symlinked parent\n'
    else
      printf 'FAIL checker symlink target: exit %s\n%s\n' "$status" "$output" >&2
      failures=$((failures + 1))
    fi

    mkdir "${check_external}/state"
    ln -s "${check_external}/state" "${check_consumer}/state"
    awk '{ if ($1 == "marker_file") { print "marker_file = \"state/syncing\""; next } print }' \
      "${check_consumer}/.nautilus-engineering.lock" > "${check_consumer}/lock.tmp"
    mv "${check_consumer}/lock.tmp" "${check_consumer}/.nautilus-engineering.lock"
    status=0
    output=$(cd "$check_consumer" &&
      bash ../source/sync/check-synced-files.bash 2>&1) || status=$?
    if [[ "$status" == 1 && "$output" == *"incomplete Nautilus engineering sync"* ]]; then
      printf 'ok   checker rejects a marker path through a symlinked parent\n'
    else
      printf 'FAIL checker symlink marker: exit %s\n%s\n' "$status" "$output" >&2
      failures=$((failures + 1))
    fi

    cp "$lock_backup" "${check_external}/state/lock"
    status=0
    output=$(cd "$check_consumer" &&
      bash ../source/sync/check-synced-files.bash --lock state/lock 2>&1) || status=$?
    if [[ "$status" == 1 && "$output" == *"not a regular file"* ]]; then
      printf 'ok   checker rejects a lock path through a symlinked parent\n'
    else
      printf 'FAIL checker symlink lock: exit %s\n%s\n' "$status" "$output" >&2
      failures=$((failures + 1))
    fi
    ;;
esac

update_source="${test_root}/update-source"
update_consumer="${test_root}/update-consumer"
mkdir -p "${update_source}/config" "${update_source}/sync" "$update_consumer"
cat > "${update_source}/config/base.txt" << 'TEXT'
base version 1
TEXT
cat > "${update_source}/config/direct.txt" << 'TEXT'
direct version 1
TEXT
cat > "${update_source}/config/future.txt" << 'TEXT'
future version 1
TEXT
cat > "${update_source}/sync/manifest.toml" << 'TOML'
version = 1
repository = "https://github.com/nautechsystems/nautilus_engineering"
lock_file = ".nautilus-engineering.lock"
marker_file = ".nautilus-engineering.syncing"

[[artifact]]
id = "base-config"
source = "config/base.txt"
target = "config/base.txt"
executable = false
profiles = ["base"]

[[artifact]]
id = "direct-config"
source = "config/direct.txt"
target = "config/direct.txt"
executable = false
profiles = ["direct"]

[[artifact]]
id = "future-config"
source = "config/future.txt"
target = "config/future.txt"
executable = false
profiles = ["future"]
TOML
git -C "$update_source" init --quiet
git -C "$update_source" config user.email test@example.com
git -C "$update_source" config user.name Test
git -C "$update_source" config commit.gpgsign false
git -C "$update_source" add -A
git -C "$update_source" commit --quiet -m source-v1
git -C "$update_consumer" init --quiet
status=0
output=$(bash "$SYNC_SCRIPT" --source "$update_source" update \
  --consumer "$update_consumer" 2>&1) || status=$?
if [[ "$status" == 2 && "$output" == *"existing sync lock not found"* ]]; then
  printf 'ok   update requires an existing consumer lock\n'
else
  printf 'FAIL update without lock: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi
bash "$SYNC_SCRIPT" --source "$update_source" vendor \
  --consumer "$update_consumer" \
  --profile base \
  --artifact direct-config \
  --target base-config=shared/base.txt > /dev/null

cat > "${update_source}/config/base.txt" << 'TEXT'
base version 2
TEXT
cat > "${update_source}/config/direct.txt" << 'TEXT'
direct version 2
TEXT
cat > "${update_source}/sync/manifest.toml" << 'TOML'
version = 1
repository = "https://github.com/nautechsystems/nautilus_engineering"
lock_file = ".nautilus-engineering.lock"
marker_file = ".nautilus-engineering.syncing"

[[artifact]]
id = "base-config"
source = "config/base.txt"
target = "config/base-moved.txt"
executable = false
profiles = ["base"]

[[artifact]]
id = "direct-config"
source = "config/direct.txt"
target = "config/direct.txt"
executable = false
profiles = ["direct"]

[[artifact]]
id = "future-config"
source = "config/future.txt"
target = "config/future.txt"
executable = false
profiles = ["base"]
TOML
git -C "$update_source" add -A
git -C "$update_source" commit --quiet -m source-v2
update_revision=$(git -C "$update_source" rev-parse HEAD)
status=0
output=$(bash "$SYNC_SCRIPT" --source "$update_source" update \
  --consumer "$update_consumer" 2>&1) || status=$?
if [[ "$status" == 0 && "$output" == *"Updated 2 artifact(s)"* ]] &&
  [[ $(< "${update_consumer}/shared/base.txt") == "base version 2" ]] &&
  [[ $(< "${update_consumer}/config/direct.txt") == "direct version 2" ]] &&
  [[ ! -e "${update_consumer}/config/base-moved.txt" ]] &&
  [[ ! -e "${update_consumer}/config/future.txt" ]] &&
  grep -Fq "revision = \"${update_revision}\"" \
    "${update_consumer}/.nautilus-engineering.lock" &&
  grep -Fq 'profiles = ["base"]' "${update_consumer}/.nautilus-engineering.lock"; then
  printf 'ok   update preserves the locked artifact set, profiles, and target overrides\n'
else
  printf 'FAIL update selection: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

status=0
output=$(bash "$SYNC_SCRIPT" --source "$update_source" update \
  --consumer "$update_consumer" \
  --add future-config \
  --target future-config=shared/future.txt 2>&1) || status=$?
locked_files=$(grep -c '^\[\[file\]\]' "${update_consumer}/.nautilus-engineering.lock")
if [[ "$status" == 0 && "$output" == *"Updated 3 artifact(s)"* ]] &&
  [[ $(< "${update_consumer}/shared/future.txt") == "future version 1" ]] &&
  [[ "$locked_files" == 3 ]] &&
  grep -Fq 'profiles = ["base"]' "${update_consumer}/.nautilus-engineering.lock"; then
  printf 'ok   update adds an artifact without restating the locked selection\n'
else
  printf 'FAIL update add: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

status=0
output=$(bash "$SYNC_SCRIPT" --source "$update_source" update \
  --consumer "$update_consumer" --add future-config 2>&1) || status=$?
if [[ "$status" == 2 && "$output" == *"artifact(s) already locked: future-config"* ]]; then
  printf 'ok   update rejects adding an already locked artifact\n'
else
  printf 'FAIL update duplicate add: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

cat > "${update_source}/sync/manifest.toml" << 'TOML'
version = 1
repository = "https://github.com/nautechsystems/nautilus_engineering"
lock_file = ".nautilus-engineering.lock"
marker_file = ".nautilus-engineering.syncing"

[[artifact]]
id = "base-config"
source = "config/base.txt"
target = "config/base-moved.txt"
executable = false
profiles = ["base"]

[[artifact]]
id = "future-config"
source = "config/future.txt"
target = "config/future.txt"
executable = false
profiles = ["base"]
TOML
git -C "$update_source" add -A
git -C "$update_source" commit --quiet -m source-v3
locked_revision=$(awk -F '"' '$1 == "revision = " { print $2 }' \
  "${update_consumer}/.nautilus-engineering.lock")
status=0
output=$(bash "$SYNC_SCRIPT" --source "$update_source" update \
  --consumer "$update_consumer" 2>&1) || status=$?
if [[ "$status" == 2 && "$output" == *"unknown artifact(s): direct-config"* ]] &&
  [[ $(< "${update_consumer}/config/direct.txt") == "direct version 2" ]] &&
  grep -Fq "revision = \"${locked_revision}\"" \
    "${update_consumer}/.nautilus-engineering.lock"; then
  printf 'ok   update rejects source manifests that cannot preserve the locked selection\n'
else
  printf 'FAIL update removed artifact: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

full_source="${test_root}/full-source"
full_consumer="${test_root}/full-consumer"
mkdir -p "${full_source}/sync" "$full_consumer"
cp "${REPO_ROOT}/sync/manifest.toml" "${full_source}/sync/manifest.toml"
while IFS= read -r source_path; do
  mkdir -p "${full_source}/$(dirname "$source_path")"
  cp -p "${REPO_ROOT}/${source_path}" "${full_source}/${source_path}"
done < <(awk -F '"' '$1 == "source = " { print $2 }' "${REPO_ROOT}/sync/manifest.toml")
git -C "$full_source" init --quiet
git -C "$full_source" config user.email test@example.com
git -C "$full_source" config user.name Test
git -C "$full_source" config commit.gpgsign false
git -C "$full_source" config core.filemode true
git -C "$full_source" add -A
while IFS= read -r source_path; do
  git -C "$full_source" update-index --chmod=+x "$source_path"
done < <(awk -F '"' '
  /^source = / { source=$2 }
  /^executable = true/ { print source }
' "${REPO_ROOT}/sync/manifest.toml")
git -C "$full_source" commit --quiet -m source

fixed_consumer="${test_root}/fixed-consumer"
mkdir "$fixed_consumer"
git -C "$fixed_consumer" init --quiet
fixed_target_failed=false
for fixed_artifact in \
  markdown-table-check \
  cargo-tool-version \
  cargo-cooldown-check \
  cargo-dependency-update \
  osv-scanner-install \
  tool-version \
  uv-version; do
  status=0
  output=$(bash "$SYNC_SCRIPT" --source "$full_source" vendor \
    --consumer "$fixed_consumer" \
    --artifact "$fixed_artifact" \
    --target "${fixed_artifact}=shared/${fixed_artifact}" 2>&1) || status=$?
  if [[ "$status" != 2 ||
    "$output" != *"artifact ${fixed_artifact} target cannot be overridden"* ]]; then
    printf 'FAIL fixed target %s: exit %s\n%s\n' "$fixed_artifact" "$status" "$output" >&2
    fixed_target_failed=true
  fi
done
if [[ "$fixed_target_failed" == false ]] &&
  [[ ! -e "${fixed_consumer}/.nautilus-engineering.syncing" ]]; then
  printf 'ok   fixed-target artifacts reject incompatible consumer paths\n'
else
  if [[ -e "${fixed_consumer}/.nautilus-engineering.syncing" ]]; then
    printf 'FAIL fixed target left a sync marker\n' >&2
  fi
  failures=$((failures + 1))
fi

git -C "$full_consumer" init --quiet
artifact_count=$(awk '$0 == "[[artifact]]" { count++ } END { print count + 0 }' \
  "${REPO_ROOT}/sync/manifest.toml")
status=0
output=$(bash "$SYNC_SCRIPT" --source "$full_source" vendor \
  --consumer "$full_consumer" --profile all 2>&1) || status=$?
if [[ "$status" == 0 && "$output" == *"Vendored ${artifact_count} artifact(s)"* ]]; then
  check_status=0
  check_output=$(cd "$full_consumer" &&
    bash scripts/check-nautilus-engineering-sync.bash 2>&1) || check_status=$?
else
  check_status=1
  check_output="full manifest vendoring failed"
fi
if [[ "$status" == 0 && "$check_status" == 0 &&
  "$check_output" == *"All ${artifact_count} synced file"* ]]; then
  printf 'ok   current manifest vendors and checks every declared artifact\n'
else
  printf 'FAIL current manifest: vendor %s, check %s\n%s\n%s\n' \
    "$status" "$check_status" "$output" "$check_output" >&2
  failures=$((failures + 1))
fi

cargo_consumer="${test_root}/cargo-consumer"
mkdir "$cargo_consumer"
git -C "$cargo_consumer" init --quiet
status=0
output=$(bash "$SYNC_SCRIPT" --source "$full_source" vendor \
  --consumer "$cargo_consumer" --profile cargo 2>&1) || status=$?
if [[ "$status" == 0 && -f "${cargo_consumer}/rustfmt.toml" ]] &&
  cmp -s "${full_source}/config/rustfmt.toml" "${cargo_consumer}/rustfmt.toml"; then
  printf 'ok   cargo profile includes the shared rustfmt configuration\n'
else
  printf 'FAIL cargo profile rustfmt configuration: exit %s\n%s\n' \
    "$status" "$output" >&2
  failures=$((failures + 1))
fi

precommit_consumer="${test_root}/precommit-consumer"
mkdir "$precommit_consumer"
git -C "$precommit_consumer" init --quiet
status=0
output=$(bash "$SYNC_SCRIPT" --source "$full_source" vendor \
  --consumer "$precommit_consumer" --profile pre-commit 2>&1) || status=$?
if [[ "$status" == 0 && "$output" == *"Vendored 11 artifact(s)"* ]] &&
  [[ -f "${precommit_consumer}/.markdownlint.jsonc" ]] &&
  [[ -f "${precommit_consumer}/.yamllint.yaml" ]] &&
  [[ -f "${precommit_consumer}/.taplo.toml" ]] &&
  [[ -f "${precommit_consumer}/scripts/check-markdown-tables.py" ]] &&
  [[ -f "${precommit_consumer}/scripts/check-nautilus-engineering-sync.bash" ]] &&
  [[ -x "${precommit_consumer}/scripts/manage-nautilus-engineering-pre-commit.py" ]] &&
  [[ -f "${precommit_consumer}/.nautilus-engineering/pre-commit/sync.yaml" ]]; then
  printf 'ok   pre-commit profile includes every referenced shared input\n'
else
  printf 'FAIL pre-commit profile dependencies: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

sync_consumer="${test_root}/sync-consumer"
mkdir "$sync_consumer"
git -C "$sync_consumer" init --quiet
status=0
output=$(bash "$SYNC_SCRIPT" --source "$full_source" vendor \
  --consumer "$sync_consumer" --profile sync 2>&1) || status=$?
if [[ "$status" == 0 && "$output" == *"Vendored 3 artifact(s)"* ]] &&
  [[ -f "${sync_consumer}/.nautilus-engineering/pre-commit/sync.yaml" ]] &&
  [[ -x "${sync_consumer}/scripts/check-nautilus-engineering-sync.bash" ]] &&
  [[ -x "${sync_consumer}/scripts/manage-nautilus-engineering-pre-commit.py" ]]; then
  printf 'ok   sync profile includes both unconditional hook dependencies\n'
else
  printf 'FAIL sync profile dependencies: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

if ((failures > 0)); then
  printf '\n%s sync test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nAll sync tests passed\n'
