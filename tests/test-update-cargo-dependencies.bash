#!/usr/bin/env bash
set -euo pipefail

# Transaction tests for scripts/update-cargo-dependencies.bash. Each case runs in
# a throwaway Git repository with fake Cargo and crates.io commands.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
UPDATE_SCRIPT="${REPO_ROOT}/scripts/update-cargo-dependencies.bash"
CHECK_SCRIPT="${REPO_ROOT}/scripts/check-cargo-cooldown.sh"
REAL_DATE="$(command -v date)"
REAL_CP="$(command -v cp)"

for required in git awk jq date grep cmp sed; do
  command -v "$required" > /dev/null || {
    echo "Required test command not on PATH: $required" >&2
    exit 1
  }
done

# Test controls must not inherit state from a developer's shell
unset FAKE_CARGO_UPDATE_FROM FAKE_CARGO_UPDATE_TO FAKE_CARGO_CASCADE_REF_CAST
unset FAKE_CARGO_FAIL_UPDATE FAKE_CARGO_FAIL_PACKAGE FAKE_CARGO_FAIL_OFFLINE_PACKAGE
unset FAKE_CARGO_DRIFT_LOCK FAKE_CARGO_METADATA_FAIL FAKE_CP_FAIL_ROOT_RESTORE

test_root="$(mktemp -d "${TMPDIR:-/tmp}/nautilus-cargo-update-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

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
crate="${url%/*}"
crate="${crate##*/}"
version="${url##*/}"
line="$(grep -E "^${crate} ${version} " "$FAKE_CRATES_FIXTURE" 2> /dev/null || true)"
[[ -n "$line" ]] || exit 22
printf '{"version":{"created_at":"%s"}}\n' "$(printf '%s' "$line" | awk '{print $3}')"
FAKE_CURL

cat > "${fake_bin}/cargo" << 'FAKE_CARGO'
#!/usr/bin/env bash
set -u

printf '%s\n' "$*" >> "${FAKE_CARGO_LOG:?}"

replace_version() {
  local lock=$1 crate=$2 current=$3 replacement=$4 tmp
  tmp="${lock}.tmp"
  if ! awk -v crate="$crate" -v current="$current" -v replacement="$replacement" '
    /^\[\[package\]\]/ { name="" }
    /^name = "/ {
      name=$0
      sub(/^name = "/, "", name)
      sub(/"$/, "", name)
    }
    /^version = "/ && name == crate {
      version=$0
      sub(/^version = "/, "", version)
      sub(/"$/, "", version)
      if (version == current) {
        print "version = \"" replacement "\""
        changed=1
        next
      }
    }
    { print }
    END { if (!changed) exit 3 }
  ' "$lock" > "$tmp"; then
    rm -f "$tmp"
    echo "fake cargo could not replace ${crate}@${current} with ${replacement} in ${lock}" >&2
    return 1
  fi
  mv "$tmp" "$lock"
}

command_name=${1:-}
shift || true
case "$command_name" in
  update)
    manifest="Cargo.toml"
    package=""
    precise=""
    offline=false
    while (($# > 0)); do
      case "$1" in
        --offline)
          offline=true
          shift
          ;;
        --manifest-path)
          manifest=$2
          shift 2
          ;;
        -p)
          package=$2
          shift 2
          ;;
        --precise)
          precise=$2
          shift 2
          ;;
        *) shift ;;
      esac
    done

    if [[ -z "$package" ]]; then
      update_from=${FAKE_CARGO_UPDATE_FROM:-1.0.0}
      update_to=${FAKE_CARGO_UPDATE_TO:-1.1.0}
      lock_path="$(dirname "$manifest")/Cargo.lock"
      replace_version "$lock_path" anyhow "$update_from" "$update_to"
      if [[ "${FAKE_CARGO_FAIL_UPDATE:-0}" == "1" ]]; then
        exit 1
      fi
      replace_version "$lock_path" serde "$update_from" "$update_to"
      if [[ "${FAKE_CARGO_CASCADE_REF_CAST:-0}" == "1" ]]; then
        replace_version "$lock_path" ref-cast 1.0.26 1.0.27
        replace_version "$lock_path" ref-cast-impl 1.0.26 1.0.27
      fi
      exit 0
    fi

    if [[ "${FAKE_CARGO_FAIL_PACKAGE:-}" == "$package" ]]; then
      exit 1
    fi
    if [[ "$offline" == true &&
      "${FAKE_CARGO_FAIL_OFFLINE_PACKAGE:-}" == "$package" ]]; then
      exit 1
    fi
    if [[ "${FAKE_CARGO_CASCADE_REF_CAST:-0}" == "1" &&
      "$package" == "ref-cast-impl@1.0.27" ]]; then
      echo "fake cargo constraint failure: ref-cast still requires ref-cast-impl 1.0.27" >&2
      exit 1
    fi
    crate=${package%@*}
    current=${package##*@}
    lock_path="$(dirname "$manifest")/Cargo.lock"
    replace_version "$lock_path" "$crate" "$current" "$precise"
    if [[ "${FAKE_CARGO_CASCADE_REF_CAST:-0}" == "1" ]]; then
      case "$package" in
        ref-cast@1.0.27)
          replace_version "$lock_path" ref-cast-impl 1.0.27 1.0.26
          ;;
      esac
    fi
    if [[ "${FAKE_CARGO_DRIFT_LOCK:-0}" == "1" ]]; then
      printf '# simulated resolver edge drift\n' >> "$lock_path"
    fi
    ;;
  metadata)
    if [[ " $* " == *" --no-deps "* ]]; then
      echo "metadata validation must include dependencies" >&2
      exit 1
    fi
    if [[ "${FAKE_CARGO_METADATA_FAIL:-0}" == "1" ]]; then
      exit 1
    fi
    ;;
  *)
    echo "unexpected fake cargo command: $command_name" >&2
    exit 2
    ;;
esac
FAKE_CARGO

cat > "${fake_bin}/cp" << 'FAKE_CP'
#!/usr/bin/env bash
set -u

args=("$@")
source_path=${args[$((${#args[@]} - 2))]}
destination=${args[$((${#args[@]} - 1))]}
if [[ "${FAKE_CP_FAIL_ROOT_RESTORE:-0}" == "1" &&
  "$source_path" == */nautilus-cargo-update.*/Cargo.lock &&
  "$destination" == "./.Cargo.lock.restore."* ]]; then
  printf 'partial snapshot copy\n' > "$destination"
  exit 1
fi
exec "$REAL_CP" "$@"
FAKE_CP

chmod +x "${fake_bin}/cargo" "${fake_bin}/cp" "${fake_bin}/curl"

fixture="${test_root}/crates.txt"
fresh_date="$($REAL_DATE -u +%Y-%m-%dT%H:%M:%SZ)"
old_date="2020-01-01T00:00:00Z"
printf 'anyhow 1.0.5 %s\nanyhow 1.1.0 %s\nserde 1.0.5 %s\nserde 1.1.0 %s\n' \
  "$old_date" "$fresh_date" "$old_date" "$fresh_date" > "$fixture"
export FAKE_CRATES_FIXTURE="$fixture"
export REAL_CP

write_root_lock() {
  local version=${1:-1.0.0}
  cat > "${repo}/Cargo.lock" << LOCK
version = 4

[[package]]
name = "anyhow"
version = "${version}"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "0000000000000000000000000000000000000000000000000000000000000000"

[[package]]
name = "serde"
version = "${version}"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "1111111111111111111111111111111111111111111111111111111111111111"
LOCK
}

setup_repo() {
  repo="${test_root}/repo-${1}"
  cargo_log="${test_root}/cargo-${1}.log"
  mkdir -p "${repo}/scripts" "${repo}/.supply-chain"
  cp "$UPDATE_SCRIPT" "$CHECK_SCRIPT" "${repo}/scripts/"
  cat > "${repo}/Cargo.toml" << 'TOML'
[workspace]
members = []

[workspace.metadata.cooldown]
days = 3
TOML
  : > "${repo}/.supply-chain/audits.toml"
  write_root_lock
  git -C "$repo" init --quiet
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m baseline
  update_tmp="${repo}/tmp"
  mkdir -p "$update_tmp"
  cp "${repo}/Cargo.lock" "${test_root}/expected-root-${1}.lock"
  : > "$cargo_log"
  export FAKE_CARGO_LOG="$cargo_log"
}

run_update() {
  (cd "$test_root" && PATH="${fake_bin}:${PATH}" TMPDIR="$update_tmp" \
    bash "${repo}/scripts/update-cargo-dependencies.bash" "$@" 2>&1)
}

failures=0

setup_repo success
status=0
output="$(FAKE_CARGO_DRIFT_LOCK=1 run_update)" || status=$?
offline_precise_commands=$(awk '/--offline/ && /--precise/ { count++ } END { print count+0 }' \
  "$cargo_log")
online_precise_commands=$(awk '!/--offline/ && /--precise/ { count++ } END { print count+0 }' \
  "$cargo_log")
if [[ "$status" == 0 && "$output" == *"Rolled back 2 fresh lockfile update(s)"* &&
  "$output" == *"Restored exact pre-update content for 1 lockfile"* &&
  "$output" == *"Cargo dependency update complete; cooldown policy enforced"* &&
  "$offline_precise_commands" == "2" && "$online_precise_commands" == "0" ]] &&
  cmp -s "${repo}/Cargo.lock" "${test_root}/expected-root-success.lock" &&
  [[ ! -e "${repo}/.git/nautilus-cargo-update.lock" ]]; then
  printf 'ok   successful update rolls back fresh crates and reports completion\n'
else
  printf 'FAIL successful transactional update: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

setup_repo invalid-argument
status=0
output="$(run_update unexpected)" || status=$?
if [[ "$status" == 2 && "$output" == *"Unknown argument: unexpected"* ]] &&
  [[ ! -s "$cargo_log" ]] &&
  cmp -s "${repo}/Cargo.lock" "${test_root}/expected-root-invalid-argument.lock"; then
  printf 'ok   invalid arguments fail before changing state\n'
else
  printf 'FAIL invalid argument handling: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

setup_repo multi-lock
mkdir -p "${repo}/nested"
printf '[workspace]\nmembers = []\n' > "${repo}/nested/Cargo.toml"
cp "${repo}/Cargo.lock" "${repo}/nested/Cargo.lock"
git -C "$repo" add nested
git -C "$repo" commit --quiet -m "add nested workspace"
cp "${repo}/Cargo.lock" "${test_root}/expected-root-multi-lock.lock"
cp "${repo}/nested/Cargo.lock" "${test_root}/expected-nested-multi-lock.lock"
: > "$cargo_log"
status=0
output=$(run_update) || status=$?
if [[ "$status" == 0 && "$output" == *"Rolled back 4 fresh lockfile update(s)"* ]] &&
  grep -Fq 'update --manifest-path nested/Cargo.toml' "$cargo_log" &&
  cmp -s "${repo}/Cargo.lock" "${test_root}/expected-root-multi-lock.lock" &&
  cmp -s "${repo}/nested/Cargo.lock" "${test_root}/expected-nested-multi-lock.lock"; then
  printf 'ok   tracked lock discovery updates and gates every Cargo workspace\n'
else
  printf 'FAIL multi-lock update: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

setup_repo selected-lock
mkdir -p "${repo}/nested"
printf '[workspace]\nmembers = []\n' > "${repo}/nested/Cargo.toml"
cp "${repo}/Cargo.lock" "${repo}/nested/Cargo.lock"
git -C "$repo" add nested
git -C "$repo" commit --quiet -m "add nested workspace"
cp "${repo}/nested/Cargo.lock" "${test_root}/expected-nested-selected-lock.lock"
: > "$cargo_log"
status=0
output=$(run_update --lock Cargo.lock) || status=$?
if [[ "$status" == 0 ]] &&
  ! grep -Fq 'update --manifest-path nested/Cargo.toml' "$cargo_log" &&
  cmp -s "${repo}/nested/Cargo.lock" "${test_root}/expected-nested-selected-lock.lock"; then
  printf 'ok   explicit lock selection leaves other workspaces unchanged\n'
else
  printf 'FAIL selected-lock update: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

setup_repo duplicate-lock
status=0
output=$(run_update --lock Cargo.lock --lock Cargo.lock) || status=$?
if [[ "$status" == 2 && "$output" == *"supplied more than once"* && ! -s "$cargo_log" ]]; then
  printf 'ok   duplicate lock selection fails before Cargo runs\n'
else
  printf 'FAIL duplicate lock selection: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

setup_repo concurrent-update
mkdir "${repo}/.git/nautilus-cargo-update.lock"
status=0
output=$(run_update) || status=$?
if [[ "$status" == 2 && "$output" == *"Another Cargo dependency update is active"* &&
  ! -s "$cargo_log" ]] &&
  cmp -s "${repo}/Cargo.lock" "${test_root}/expected-root-concurrent-update.lock"; then
  printf 'ok   an existing transaction lock blocks a concurrent update\n'
else
  printf 'FAIL concurrent update lock: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi
rmdir "${repo}/.git/nautilus-cargo-update.lock"

setup_repo update-failure
status=0
output="$(FAKE_CARGO_FAIL_UPDATE=1 run_update)" || status=$?
if [[ "$status" != 0 && "$output" == *"Cargo dependency update failed"* &&
  "$output" == *"Cargo dependency update restored the pre-update lockfiles"* ]] &&
  cmp -s "${repo}/Cargo.lock" "${test_root}/expected-root-update-failure.lock"; then
  printf 'ok   failed partial Cargo update restores the pre-update lockfile\n'
else
  printf 'FAIL failed Cargo update handling: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

setup_repo resolver-cascade
cat >> "${repo}/Cargo.lock" << 'LOCK'

[[package]]
name = "ref-cast"
version = "1.0.26"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "2222222222222222222222222222222222222222222222222222222222222222"

[[package]]
name = "ref-cast-impl"
version = "1.0.26"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "3333333333333333333333333333333333333333333333333333333333333333"
LOCK
git -C "$repo" add Cargo.lock
git -C "$repo" commit --quiet --amend --no-edit
cp "${repo}/Cargo.lock" "${test_root}/expected-root-resolver-cascade.lock"
printf 'ref-cast 1.0.27 %s\nref-cast-impl 1.0.27 %s\n' \
  "$fresh_date" "$fresh_date" >> "$fixture"
: > "$cargo_log"
status=0
output="$(FAKE_CARGO_CASCADE_REF_CAST=1 run_update)" || status=$?
ref_cast_commands=$(grep -Ec -- '-p ref-cast(-impl)?@1\.0\.27' "$cargo_log" || true)
online_precise_commands=$(awk '!/--offline/ && /--precise/ { count++ } END { print count+0 }' \
  "$cargo_log")
# Locale collation can order either crate first. Both paths are valid because
# rolling back ref-cast also resolves ref-cast-impl transitively.
if [[ "$status" == 0 && "$output" == *"resolved by earlier Cargo update"* &&
  "$output" != *"fake cargo constraint failure"* && "$online_precise_commands" == "0" ]] &&
  ((ref_cast_commands >= 1 && ref_cast_commands <= 2)) &&
  cmp -s "${repo}/Cargo.lock" "${test_root}/expected-root-resolver-cascade.lock"; then
  printf 'ok   transitive rollback invalidates no later Cargo package specification\n'
else
  printf 'FAIL resolver cascade handling: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

setup_repo offline-fallback
status=0
output="$(FAKE_CARGO_FAIL_OFFLINE_PACKAGE=anyhow@1.1.0 run_update)" || status=$?
if [[ "$status" == 0 &&
  "$output" == *"retrying 1 remaining rollback(s) with network access"* ]] &&
  grep -Fq -- \
    'update --offline --manifest-path Cargo.toml -p anyhow@1.1.0 --precise 1.0.0' \
    "$cargo_log" &&
  grep -Fq -- 'update --manifest-path Cargo.toml -p anyhow@1.1.0 --precise 1.0.0' \
    "$cargo_log" &&
  cmp -s "${repo}/Cargo.lock" "${test_root}/expected-root-offline-fallback.lock"; then
  printf 'ok   unavailable offline resolution retries online and restores the baseline\n'
else
  printf 'FAIL offline rollback fallback: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

setup_repo dirty
write_root_lock 1.0.5
cp "${repo}/Cargo.lock" "${test_root}/expected-root-dirty.lock"
status=0
output="$(FAKE_CARGO_UPDATE_FROM=1.0.5 run_update)" || status=$?
if [[ "$status" == 0 && "$output" == *"1.1.0 -> 1.0.5 (Cargo.lock)"* ]] &&
  cmp -s "${repo}/Cargo.lock" "${test_root}/expected-root-dirty.lock"; then
  printf 'ok   successful update preserves the pre-update staged lock baseline\n'
else
  printf 'FAIL update discarded the pre-update staged lock baseline: exit %s\n%s\n' \
    "$status" "$output" >&2
  failures=$((failures + 1))
fi

# `anyhow` is repaired first; failing the later `serde` repair proves the
# wrapper restores the entire snapshot after a partial selective rollback.
setup_repo rollback
status=0
output="$(FAKE_CARGO_FAIL_PACKAGE=serde@1.1.0 run_update)" || status=$?
if [[ "$status" != 0 &&
  "$output" == *"Cargo dependency update restored the pre-update lockfiles"* ]] &&
  grep -Fq -- '-p anyhow@1.1.0 --precise 1.0.0' "$cargo_log" &&
  grep -Fq -- '-p serde@1.1.0 --precise 1.0.0' "$cargo_log" &&
  cmp -s "${repo}/Cargo.lock" "${test_root}/expected-root-rollback.lock"; then
  printf 'ok   failed partial repair restores the pre-update lockfile\n'
else
  printf 'FAIL failed transactional update: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

setup_repo validation
status=0
output="$(FAKE_CARGO_METADATA_FAIL=1 run_update)" || status=$?
if [[ "$status" != 0 && "$output" == *"Cargo metadata validation failed"* &&
  "$output" == *"Cargo dependency update restored the pre-update lockfiles"* ]] &&
  cmp -s "${repo}/Cargo.lock" "${test_root}/expected-root-validation.lock"; then
  printf 'ok   failed post-repair validation restores the pre-update lockfile\n'
else
  printf 'FAIL failed post-repair validation: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

setup_repo restore-fails-atomically
status=0
output="$(FAKE_CARGO_FAIL_PACKAGE=serde@1.1.0 \
  FAKE_CP_FAIL_ROOT_RESTORE=1 \
  run_update)" || status=$?
snapshot_dirs=("${update_tmp}"/nautilus-cargo-update.*)
restore_temps=("${repo}"/.Cargo.lock.restore.*)
if [[ "$status" != 0 && "$output" == *"Could not restore Cargo.lock"* &&
  "$output" == *"could not restore every pre-update lockfile"* &&
  "$output" == *"Pre-update snapshots retained at"* ]] &&
  [[ -d "${snapshot_dirs[0]}" ]] &&
  [[ -d "${repo}/.git/nautilus-cargo-update.lock" ]] &&
  [[ ! -e "${restore_temps[0]}" ]] &&
  [[ -f "${repo}/Cargo.lock" ]] &&
  ! grep -Fq 'partial snapshot copy' "${repo}/Cargo.lock" &&
  [[ -f "${snapshot_dirs[0]}/Cargo.lock" ]] &&
  cmp -s "${snapshot_dirs[0]}/Cargo.lock" \
    "${test_root}/expected-root-restore-fails-atomically.lock"; then
  printf 'ok   failed atomic restore leaves the lock intact and retains its snapshot\n'
else
  printf 'FAIL atomic restoration failure handling: exit %s\n%s\n' \
    "$status" "$output" >&2
  failures=$((failures + 1))
fi

if ((failures > 0)); then
  printf '\n%s update-cargo-dependencies test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nAll update-cargo-dependencies tests passed\n'
