#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-security-install-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
fixture="${test_root}/fixture"
fake_bin="${test_root}/fake-bin"
state="${test_root}/state"
command_log="${test_root}/commands.log"
mkdir -p "${fixture}/.nautilus-engineering" "${fixture}/scripts" "$fake_bin" "$state"
cp \
  "${REPO_ROOT}/scripts/cargo-tool-version.sh" \
  "${REPO_ROOT}/scripts/install-security-tools.sh" \
  "${REPO_ROOT}/scripts/tool-version.sh" \
  "${fixture}/scripts/"

write_shared_catalog() {
  local cargo_audit_version=$1

  cat > "${fixture}/.nautilus-engineering/tools.toml" << TOML
[cargo-audit]
version = "${cargo_audit_version}"

[cargo-deny]
version = "0.20.2"

[cargo-vet]
version = "0.10.2"

[osv-scanner]
version = "2.5.1"
TOML
}
write_shared_catalog 0.22.2
cat > "${fixture}/scripts/install-osv-scanner.sh" << 'FAKE_INSTALL_OSV'
#!/usr/bin/env bash
set -euo pipefail
printf 'osv-installer\n' >> "${FAKE_COMMAND_LOG:?}"
FAKE_INSTALL_OSV
cat > "${fake_bin}/osv-scanner" << 'FAKE_OSV'
#!/usr/bin/env bash
printf 'osv-scanner version 2.5.1\n'
FAKE_OSV
cat > "${fake_bin}/cargo" << 'FAKE_CARGO'
#!/usr/bin/env bash
set -euo pipefail
printf 'cargo|%s\n' "$*" >> "${FAKE_COMMAND_LOG:?}"
if [[ "$1" == install ]]; then
  package=$2
  version=$4
  case "$package" in
    cargo-audit) subcommand=audit ;;
    cargo-deny) subcommand=deny ;;
    cargo-vet) subcommand=vet ;;
    *) exit 2 ;;
  esac
  if [[ "${FAKE_INSTALL_MISMATCH:-}" == "$subcommand" ]]; then
    version=0.0.0
  fi
  printf '%s\n' "$version" > "${FAKE_CARGO_STATE:?}/${subcommand}"
  exit 0
fi
subcommand=$1
if [[ "${2:-}" != --version || ! -f "${FAKE_CARGO_STATE:?}/${subcommand}" ]]; then
  exit 1
fi
version=$(cat "${FAKE_CARGO_STATE}/${subcommand}")
printf 'cargo-%s %s\n' "$subcommand" "$version"
FAKE_CARGO
chmod +x \
  "${fake_bin}/cargo" \
  "${fake_bin}/osv-scanner" \
  "${fixture}/scripts/install-osv-scanner.sh" \
  "${fixture}/scripts/install-security-tools.sh"

run_install() {
  FAKE_CARGO_STATE="$state" \
    FAKE_COMMAND_LOG="$command_log" \
    PATH="${SECURITY_TEST_PATH:-${fake_bin}:${PATH}}" \
    "$@" \
    bash "${fixture}/scripts/install-security-tools.sh" 2>&1
}

printf '0.22.2\n' > "${state}/audit"
printf '0.19.0\n' > "${state}/deny"
: > "$command_log"
failures=0
status=0
output=$(run_install env) || status=$?
if [[ "$status" == 0 && "$output" == *"cargo-audit 0.22.2 is already installed"* ]] &&
  grep -Fqx 'cargo|install cargo-deny --version 0.20.2 --locked --force' "$command_log" &&
  grep -Fqx 'cargo|install cargo-vet --version 0.10.2 --locked --force' "$command_log" &&
  ! grep -Fq 'install cargo-audit' "$command_log" &&
  grep -Fqx 'osv-installer' "$command_log"; then
  printf 'ok   installer skips matching tools and installs exact stale or missing versions\n'
else
  printf 'FAIL exact installs: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

: > "$command_log"
status=0
output=$(run_install env) || status=$?
if [[ "$status" == 0 ]] && ! grep -Fq 'cargo|install ' "$command_log" &&
  grep -Fqx 'osv-installer' "$command_log"; then
  printf 'ok   second run leaves matching Cargo tools unchanged\n'
else
  printf 'FAIL idempotent install: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

for version in 0.22.2-alpha 0.22.2-beta.1 0.22.2-rc.1 0.22.2+local 0.22.2.1; do
  printf '%s\n' "$version" > "${state}/audit"
  : > "$command_log"
  status=0
  output=$(run_install env) || status=$?
  if [[ "$status" == 0 ]] &&
    grep -Fqx 'cargo|install cargo-audit --version 0.22.2 --locked --force' "$command_log" &&
    [[ $(< "${state}/audit") == 0.22.2 ]]; then
    printf 'ok   installed version %s does not satisfy the stable pin\n' "$version"
  else
    printf 'FAIL installed version %s: exit %s\n%s\n' "$version" "$status" "$output" >&2
    failures=$((failures + 1))
  fi
done

rm "${state}/vet"
: > "$command_log"
status=0
output=$(run_install env FAKE_INSTALL_MISMATCH=vet) || status=$?
if [[ "$status" == 1 && "$output" == *"cargo-vet version mismatch after install"* ]] &&
  ! grep -Fqx 'osv-installer' "$command_log"; then
  printf 'ok   post-install version mismatch fails before OSV installation\n'
else
  printf 'FAIL post-install verification: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

printf '0.10.2\n' > "${state}/vet"
mv "${fake_bin}/osv-scanner" "${fake_bin}/osv-scanner.disabled"
: > "$command_log"
status=0
output=$(SECURITY_TEST_PATH="${fake_bin}:/usr/bin:/bin" run_install env) || status=$?
mv "${fake_bin}/osv-scanner.disabled" "${fake_bin}/osv-scanner"
if [[ "$status" == 1 && "$output" == *"osv-scanner was installed outside PATH"* ]] &&
  grep -Fqx 'osv-installer' "$command_log"; then
  printf 'ok   OSV installation outside PATH fails aggregate verification\n'
else
  printf 'FAIL OSV PATH verification: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

write_shared_catalog 0.22.2-rc.1
: > "$command_log"
status=0
output=$(run_install env) || status=$?
if [[ "$status" == 1 &&
  "$output" == *"cargo-audit version pin must be a stable X.Y.Z release: 0.22.2-rc.1"* ]] &&
  [[ ! -s "$command_log" ]]; then
  printf 'ok   unstable catalog pin fails before installation\n'
else
  printf 'FAIL unstable catalog pin: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

if ((failures > 0)); then
  printf '\n%s security installer test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nAll security installer tests passed\n'
