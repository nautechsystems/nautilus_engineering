#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    printf 'Skipping security audit process test on native Windows\n'
    exit 0
    ;;
esac
test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-security-audit-test.XXXXXX")
test_root=$(cd "$test_root" && pwd -P)
trap 'rm -rf "$test_root"' EXIT
fixture="${test_root}/fixture"
fake_bin="${test_root}/fake-bin"
command_log="${test_root}/commands.log"
mkdir -p \
  "${fixture}/.nautilus-engineering" \
  "${fixture}/fuzz/.supply-chain" \
  "${fixture}/python" \
  "${fixture}/scripts" \
  "${fixture}/supply-chain" \
  "${fixture}/web" \
  "$fake_bin"
cp "${REPO_ROOT}/scripts/security-audit.py" "${fixture}/scripts/"

cat > "${fixture}/.nautilus-engineering/tools.toml" << 'TOML'
[cargo-audit]
version = "0.22.2"

[cargo-deny]
version = "0.20.2"

[cargo-vet]
version = "0.10.2"

[uv]
version = "0.12.6"

[pip-audit]
version = "2.10.1"

[osv-scanner]
version = "2.5.1"
TOML
touch \
  "${fixture}/Cargo.lock" \
  "${fixture}/Cargo.toml" \
  "${fixture}/deny.toml" \
  "${fixture}/fuzz/Cargo.lock" \
  "${fixture}/fuzz/Cargo.toml" \
  "${fixture}/fuzz/deny.toml" \
  "${fixture}/osv-scanner.toml" \
  "${fixture}/python/pyproject.toml" \
  "${fixture}/python/uv.lock" \
  "${fixture}/web/package-lock.json" \
  "${fixture}/web/package.json"
cat > "${fixture}/tools.toml" << 'TOML'
[local-tool]
version = "1.0.0"
TOML

cat > "${fixture}/security-audit.toml" << 'TOML'
version = 1

[[cargo.audit]]
lockfile = "Cargo.lock"
ignore = ["RUSTSEC-2026-0001"]
deny = ["warnings"]
report = true

[[cargo.audit]]
lockfile = "fuzz/Cargo.lock"

[[cargo.deny]]
manifest = "Cargo.toml"
config = "deny.toml"
all-features = true
locked = true

[[cargo.deny]]
manifest = "fuzz/Cargo.toml"
config = "fuzz/deny.toml"
checks = ["advisories", "bans"]

[[cargo.vet]]
manifest = "Cargo.toml"
store = "supply-chain"
locked = true

[[cargo.vet]]
manifest = "fuzz/Cargo.toml"
store = "fuzz/.supply-chain"

[[python]]
project = "python"
python = "3.12"
all-extras = true
groups = ["dev", "test"]
ignore-vulns = ["PYSEC-2026-0001"]

[[node]]
project = "web"
production = true
full = "report"
signatures = true

[osv]
config = "osv-scanner.toml"
lockfiles = ["Cargo.lock", "fuzz/Cargo.lock", "python/uv.lock", "web/package-lock.json"]
report = true
TOML

cat > "${fake_bin}/cargo" << 'FAKE_CARGO'
#!/usr/bin/env bash
set -euo pipefail
printf 'cargo|%s|%s\n' "$PWD" "$*" >> "${FAKE_COMMAND_LOG:?}"
case "$*" in
  "audit --version") printf 'cargo-audit %s\n' "${FAKE_CARGO_AUDIT_VERSION:-0.22.2}" ;;
  "deny --version") printf 'cargo-deny 0.20.2\n' ;;
  "vet --version") printf 'cargo-vet 0.10.2\n' ;;
  *)
    if [[ "${FAKE_CARGO_AUDIT_FAIL:-0}" == 1 &&
      "$*" == "audit --color never --file Cargo.lock --ignore RUSTSEC-2026-0001 --deny warnings" ]]; then
      echo "root Cargo audit finding" >&2
      exit 1
    fi
    printf 'cargo audit output\n'
    ;;
esac
FAKE_CARGO
cat > "${fake_bin}/uv" << 'FAKE_UV'
#!/usr/bin/env bash
set -euo pipefail
printf 'uv|%s|%s\n' "$PWD" "$*" >> "${FAKE_COMMAND_LOG:?}"
case "$*" in
  "--version") printf 'uv 0.12.6\n' ;;
  *"pip-audit --version") printf 'pip-audit 2.10.1\n' ;;
  export*) printf 'package==1.0 --hash=sha256:abc\n' ;;
  *) printf 'No known vulnerabilities found\n' ;;
esac
FAKE_UV
cat > "${fake_bin}/npm" << 'FAKE_NPM'
#!/usr/bin/env bash
set -euo pipefail
printf 'npm|%s|%s\n' "$PWD" "$*" >> "${FAKE_COMMAND_LOG:?}"
if [[ "$*" == "audit" && "${FAKE_NPM_FULL_FAIL:-0}" == 1 ]]; then
  echo "development-only finding" >&2
  exit 1
fi
FAKE_NPM
cat > "${fake_bin}/osv-scanner" << 'FAKE_OSV'
#!/usr/bin/env bash
set -euo pipefail
printf 'osv|%s|%s\n' "$PWD" "$*" >> "${FAKE_COMMAND_LOG:?}"
if [[ "$*" == "--version" ]]; then
  printf 'osv-scanner version 2.5.1\n'
else
  printf 'OSV scan complete\n'
fi
FAKE_OSV
chmod +x "${fake_bin}/cargo" "${fake_bin}/npm" "${fake_bin}/osv-scanner" "${fake_bin}/uv"

failures=0
run_audit() {
  local command=$1
  shift
  FAKE_COMMAND_LOG="$command_log" \
    PATH="${fake_bin}:${PATH}" \
    python3 "${fixture}/scripts/security-audit.py" \
    "$command" \
    --root "$fixture" \
    "$@"
}

: > "$command_log"
status=0
output=$(FAKE_NPM_FULL_FAIL=1 run_audit run 2>&1) || status=$?
expected_commands=(
  "cargo|${fixture}|audit --color never --file Cargo.lock --ignore RUSTSEC-2026-0001 --deny warnings"
  "cargo|${fixture}|audit --color never --file fuzz/Cargo.lock"
  "cargo|${fixture}|deny --manifest-path Cargo.toml --config deny.toml --all-features --locked check advisories licenses sources bans"
  "cargo|${fixture}|deny --manifest-path fuzz/Cargo.toml --config fuzz/deny.toml check advisories bans"
  "cargo|${fixture}|vet --manifest-path Cargo.toml --store-path supply-chain --locked"
  "cargo|${fixture}|vet --manifest-path fuzz/Cargo.toml --store-path fuzz/.supply-chain"
  "uv|${fixture}|export --project python --python 3.12 --no-emit-local --frozen --all-extras --group dev --group test"
  "npm|${fixture}/web|audit --omit=dev"
  "npm|${fixture}/web|audit"
  "npm|${fixture}/web|audit signatures --min-release-age=0"
  "osv|${fixture}|scan source --config=osv-scanner.toml --lockfile=Cargo.lock --lockfile=fuzz/Cargo.lock --lockfile=python/uv.lock --lockfile=web/package-lock.json"
)
missing=0
for command in "${expected_commands[@]}"; do
  if ! grep -Fqx "$command" "$command_log"; then
    printf 'Missing command: %s\n' "$command" >&2
    missing=$((missing + 1))
  fi
done
if [[ "$status" == 0 && "$missing" == 0 && "$output" == *"development-only finding"* &&
  "$output" == *"All configured supply-chain audits passed"* ]]; then
  printf 'ok   all configured ecosystems and secondary paths run with typed flags\n'
else
  printf 'FAIL complete audit: exit %s, missing %s\n%s\n' "$status" "$missing" "$output" >&2
  failures=$((failures + 1))
fi

: > "$command_log"
status=0
output=$(FAKE_CARGO_AUDIT_FAIL=1 run_audit run 2>&1) || status=$?
if [[ "$status" == 1 && "$output" == *"root Cargo audit finding"* &&
  "$output" == *"1 audit step(s) failed"* ]] &&
  grep -Fq "osv|${fixture}|scan source" "$command_log"; then
  printf 'ok   gating failure is aggregated after later dependency surfaces run\n'
else
  printf 'FAIL gating audit: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

: > "$command_log"
status=0
output=$(FAKE_CARGO_AUDIT_VERSION=0.21.0 run_audit check-tools 2>&1) || status=$?
if [[ "$status" == 1 && "$output" == *"cargo-audit version mismatch"* ]] &&
  ! grep -Fq 'audit --color' "$command_log"; then
  printf 'ok   tool mismatch stops before dependency auditing\n'
else
  printf 'FAIL version mismatch: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

cat >> "${fixture}/tools.toml" << 'TOML'

[cargo-audit]
version = "0.21.0"
TOML
: > "$command_log"
status=0
output=$(run_audit check-tools 2>&1) || status=$?
if [[ "$status" == 1 && "$output" == *"duplicate [cargo-audit] table"* ]] &&
  [[ ! -s "$command_log" ]]; then
  printf 'ok   duplicate shared and local scanner pins fail before tool execution\n'
else
  printf 'FAIL duplicate scanner pin: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

cat > "${fixture}/invalid.toml" << 'TOML'
version = 1
unexpected = true

[[node]]
project = "web"
TOML
status=0
output=$(run_audit validate --config invalid.toml 2>&1) || status=$?
if [[ "$status" == 1 && "$output" == *"unknown field(s): unexpected"* ]]; then
  printf 'ok   unknown policy fields fail validation\n'
else
  printf 'FAIL unknown policy field: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

cat > "${fixture}/unsafe.toml" << 'TOML'
version = 1

[[node]]
project = "../outside"
TOML
status=0
output=$(run_audit validate --config unsafe.toml 2>&1) || status=$?
if [[ "$status" == 1 && "$output" == *"must stay within the repository"* ]]; then
  printf 'ok   repository path traversal fails validation\n'
else
  printf 'FAIL unsafe path: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

cat > "${fixture}/disabled-node.toml" << 'TOML'
version = 1

[[node]]
project = "web"
production = false
full = "off"
signatures = false
TOML
status=0
output=$(run_audit validate --config disabled-node.toml 2>&1) || status=$?
if [[ "$status" == 1 && "$output" == *"must enable at least one audit"* ]]; then
  printf 'ok   disabled Node policy fails validation\n'
else
  printf 'FAIL disabled Node policy: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

if ((failures > 0)); then
  printf '\n%s security audit test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nAll security audit tests passed\n'
