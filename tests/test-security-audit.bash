#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
native_windows=false
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) native_windows=true ;;
esac
test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-security-audit-test.XXXXXX")
test_root=$(cd "$test_root" && pwd -P)
trap 'rm -rf "$test_root"' EXIT
fixture="${test_root}/fixture"
fake_bin="${test_root}/fake-bin"
proxy_bin="${test_root}/proxy-bin"
command_log="${test_root}/commands.log"
fixture_log="$fixture"
mkdir -p \
  "${fixture}/.nautilus-engineering" \
  "${fixture}/fuzz/.supply-chain" \
  "${fixture}/python" \
  "${fixture}/scripts" \
  "${fixture}/supply-chain" \
  "${fixture}/web" \
  "$fake_bin" \
  "$proxy_bin"
cp "${REPO_ROOT}/scripts/security-audit.py" "${fixture}/scripts/"

write_shared_catalog() {
  local cargo_audit_version=$1

  cat > "${fixture}/.nautilus-engineering/tools.toml" << TOML
[cargo-audit]
version = "${cargo_audit_version}"

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
}
write_shared_catalog 0.22.2
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

[[cargo.deny]]
manifest = "fuzz/Cargo.toml"
config = "fuzz/deny.toml"
checks = ["advisories", "bans"]

[[cargo.vet]]
manifest = "Cargo.toml"
store = "supply-chain"

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

if [[ "$native_windows" == true ]]; then
  if [[ $(python3 -c 'import sys; print(sys.platform)') == win32 ]]; then
    fixture_log=fixture
  fi
  cat > "${fake_bin}/fake-command.py" << 'FAKE_COMMAND'
#!/usr/bin/env python3
import os
from pathlib import Path
import sys


def display_cwd() -> str:
    root = Path(__file__).resolve().parent.parent / "fixture"
    relative = Path.cwd().resolve().relative_to(root)
    if relative.parts:
        return f"fixture/{relative.as_posix()}"
    return "fixture"


tool = sys.argv[1]
arguments = sys.argv[2:]
command = " ".join(arguments)
command_log = Path(__file__).resolve().parent.parent / "commands.log"
with command_log.open("a", encoding="utf-8", newline="\n") as log:
    label = "osv" if tool == "osv-scanner" else tool
    print(f"{label}|{display_cwd()}|{command}", file=log)

if tool == "cargo":
    if command == "audit --version":
        print(f"cargo-audit {os.environ.get('FAKE_CARGO_AUDIT_VERSION', '0.22.2')}")
    elif command == "deny --version":
        print("cargo-deny 0.20.2")
    elif command == "vet --version":
        print("cargo-vet 0.10.2")
    elif (
        os.environ.get("FAKE_CARGO_AUDIT_FAIL") == "1"
        and command
        == "audit --color never --file Cargo.lock --ignore RUSTSEC-2026-0001 --deny warnings"
    ):
        print("root Cargo audit finding", file=sys.stderr)
        sys.exit(1)
    else:
        print("cargo audit output")
elif tool == "uv":
    if command == "--version":
        print("uv 0.12.6")
    elif "pip-audit --version" in command:
        print("pip-audit 2.10.1")
    elif arguments and arguments[0] == "export":
        print("package==1.0 --hash=sha256:abc")
    else:
        print("No known vulnerabilities found")
elif tool == "npm":
    if command == "--version":
        if os.environ.get("FAKE_NPM_INVALID_UTF8") == "1":
            sys.stdout.buffer.write(b"\xff\n")
        else:
            print("12.0.2")
    elif command == "audit" and os.environ.get("FAKE_NPM_FULL_FAIL") == "1":
        print("development-only finding", file=sys.stderr)
        sys.exit(1)
elif tool == "osv-scanner":
    if command == "--version":
        print("osv-scanner version 2.5.1")
        print("osv-scalibr version 0.5.2")
    else:
        print("OSV scan complete")
else:
    print(f"unexpected fake command: {tool}", file=sys.stderr)
    sys.exit(2)
FAKE_COMMAND
  for tool in cargo npm osv-scanner uv; do
    printf '@echo off\r\npython3 "%%~dp0fake-command.py" %s %%*\r\n' "$tool" \
      > "${fake_bin}/${tool}.cmd"
  done
fi

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
if [[ "$*" == "--version" ]]; then
  if [[ "${FAKE_NPM_INVALID_UTF8:-0}" == 1 ]]; then
    printf '\377\n'
  else
    printf '12.0.2\n'
  fi
elif [[ "$*" == "audit" && "${FAKE_NPM_FULL_FAIL:-0}" == 1 ]]; then
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
  printf 'osv-scalibr version 0.5.2\n'
else
  printf 'OSV scan complete\n'
fi
FAKE_OSV
chmod +x "${fake_bin}/cargo" "${fake_bin}/npm" "${fake_bin}/osv-scanner" "${fake_bin}/uv"

if [[ "$native_windows" == false ]]; then
  cat > "${proxy_bin}/rustup" << 'FAKE_RUSTUP'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$(basename "$0")" != cargo ]]; then
  echo "rustup proxy was invoked without the cargo alias" >&2
  exit 1
fi
exec "${FAKE_CARGO_TARGET:?}" "$@"
FAKE_RUSTUP
  chmod +x "${proxy_bin}/rustup"
  ln -s rustup "${proxy_bin}/cargo"
fi

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

if [[ "$native_windows" == true ]]; then
  printf 'Skipping Unix proxy alias fixture on native Windows\n'
else
  : > "$command_log"
  status=0
  output=$(FAKE_CARGO_TARGET="${fake_bin}/cargo" \
    FAKE_COMMAND_LOG="$command_log" \
    PATH="${proxy_bin}:${fake_bin}:${PATH}" \
    python3 "${fixture}/scripts/security-audit.py" \
    check-tools \
    --root "$fixture" 2>&1) || status=$?
  if [[ "$status" == 0 && "$output" == *"All required supply-chain tools"* ]] &&
    grep -Fq "cargo|${fixture}|audit --version" "$command_log"; then
    printf 'ok   executable resolution preserves rustup proxy aliases\n'
  else
    printf 'FAIL rustup proxy alias: exit %s\n%s\n' "$status" "$output" >&2
    failures=$((failures + 1))
  fi
fi

: > "$command_log"
status=0
output=$(FAKE_NPM_FULL_FAIL=1 run_audit run 2>&1) || status=$?
expected_commands=(
  "cargo|${fixture_log}|audit --color never --file Cargo.lock --ignore RUSTSEC-2026-0001 --deny warnings"
  "cargo|${fixture_log}|audit --color never --file fuzz/Cargo.lock"
  "cargo|${fixture_log}|deny --manifest-path Cargo.toml --config deny.toml --all-features --locked check advisories licenses sources bans"
  "cargo|${fixture_log}|deny --manifest-path fuzz/Cargo.toml --config fuzz/deny.toml --locked check advisories bans"
  "cargo|${fixture_log}|vet --manifest-path Cargo.toml --store-path supply-chain --locked"
  "cargo|${fixture_log}|vet --manifest-path fuzz/Cargo.toml --store-path fuzz/.supply-chain --locked"
  "uv|${fixture_log}|export --project python --python 3.12 --no-emit-local --frozen --all-extras --group dev --group test"
  "npm|${fixture_log}|--version"
  "npm|${fixture_log}/web|audit --omit=dev"
  "npm|${fixture_log}/web|audit"
  "npm|${fixture_log}/web|audit signatures --min-release-age=0"
  "osv|${fixture_log}|scan source --config=osv-scanner.toml --lockfile=Cargo.lock --lockfile=fuzz/Cargo.lock --lockfile=python/uv.lock --lockfile=web/package-lock.json"
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
  grep -Fq "osv|${fixture_log}|scan source" "$command_log"; then
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

for version in 0.22.2-alpha 0.22.2-beta.1 0.22.2-rc.1 0.22.2+local 0.22.2.1; do
  : > "$command_log"
  status=0
  output=$(FAKE_CARGO_AUDIT_VERSION="$version" run_audit check-tools 2>&1) || status=$?
  if [[ "$status" == 1 && "$output" == *"cargo-audit version mismatch"* &&
    "$output" == *"$version"* ]] &&
    ! grep -Fq 'audit --color' "$command_log"; then
    printf 'ok   reported version %s does not satisfy the stable pin\n' "$version"
  else
    printf 'FAIL reported version %s: exit %s\n%s\n' \
      "$version" "$status" "$output" >&2
    failures=$((failures + 1))
  fi
done

for version in 0.22.2-alpha 0.22.2-beta.1 0.22.2-rc.1 0.22.2+local 0.22.2.1; do
  write_shared_catalog "$version"
  : > "$command_log"
  status=0
  output=$(run_audit check-tools 2>&1) || status=$?
  if [[ "$status" == 1 &&
    "$output" == *"[cargo-audit].version must be a stable X.Y.Z release"* ]] &&
    [[ ! -s "$command_log" ]]; then
    printf 'ok   shared catalog rejects unstable pin %s\n' "$version"
  else
    printf 'FAIL unstable shared pin %s: exit %s\n%s\n' \
      "$version" "$status" "$output" >&2
    failures=$((failures + 1))
  fi
done
write_shared_catalog 0.22.2

status=0
output=$(FAKE_NPM_INVALID_UTF8=1 run_audit check-tools 2>&1) || status=$?
if [[ "$status" == 0 && "$output" == *"All required supply-chain tools"* ]]; then
  printf 'ok   undecodable tool output cannot escape the audit error boundary\n'
else
  printf 'FAIL tool output decoding: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

cp "${fake_bin}/npm" "${fake_bin}/npm.good"
printf 'invalid executable\n' > "${fake_bin}/npm"
chmod +x "${fake_bin}/npm"
if [[ "$native_windows" == true ]]; then
  mv "${fake_bin}/npm.cmd" "${fake_bin}/npm.cmd.good"
fi
: > "$command_log"
status=0
output=$(run_audit check-tools 2>&1) || status=$?
if [[ "$native_windows" == true ]]; then
  mv "${fake_bin}/npm.cmd.good" "${fake_bin}/npm.cmd"
fi
mv "${fake_bin}/npm.good" "${fake_bin}/npm"
if [[ "$status" == 1 && "$output" == *"could not execute"* &&
  "$output" != *"Traceback"* ]]; then
  printf 'ok   process launch failure reports a clean audit error\n'
else
  printf 'FAIL process launch error: exit %s\n%s\n' "$status" "$output" >&2
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
