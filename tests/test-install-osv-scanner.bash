#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-osv-install-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
fixture="${test_root}/fixture"
fake_bin="${test_root}/fake-bin"
mkdir -p "${fixture}/scripts" "$fake_bin"
cp "${REPO_ROOT}/scripts/install-osv-scanner.sh" "${fixture}/scripts/"
cp "${REPO_ROOT}/scripts/tool-version.sh" "${fixture}/scripts/"
write_catalog() {
  local version=$1

  cat > "${fixture}/tools.toml" << TOML
[osv-scanner]
version = "${version}"
TOML
}
write_catalog 2.5.0

cat > "${fake_bin}/uname" << 'FAKE_UNAME'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "${FAKE_UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${FAKE_UNAME_M:-x86_64}" ;;
  *) exit 2 ;;
esac
FAKE_UNAME
cat > "${fake_bin}/sleep" << 'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
cat > "${fake_bin}/curl" << 'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_CURL_LOG:?}"
output=""
while (($# > 0)); do
  if [[ "$1" == "-o" ]]; then
    output=$2
    shift 2
  else
    shift
  fi
done
case "$output" in
  osv-scanner_SHA256SUMS)
    if [[ "${FAKE_CHECKSUM_MODE:-valid}" == missing ]]; then
      printf '%064d  another_asset\n' 0 > "$output"
    elif [[ "${FAKE_CHECKSUM_MODE:-valid}" == mismatch ]]; then
      printf '%064d  osv-scanner_linux_amd64\n' 0 > "$output"
    else
      if command -v sha256sum > /dev/null 2>&1; then
        hash=$(sha256sum osv-scanner_linux_amd64 | awk '{ print $1 }')
      else
        hash=$(shasum -a 256 osv-scanner_linux_amd64 | awk '{ print $1 }')
      fi
      printf '%s  osv-scanner_linux_amd64\n' "$hash" > "$output"
    fi
    ;;
  osv-scanner_linux_amd64)
    printf '#!/usr/bin/env bash\necho "osv-scanner version %s"\n' \
      "${FAKE_ASSET_VERSION:-2.5.0}" > "$output"
    ;;
  *)
    echo "Unexpected curl output path: $output" >&2
    exit 2
    ;;
esac
FAKE_CURL
chmod +x "${fake_bin}/curl" "${fake_bin}/sleep" "${fake_bin}/uname"

failures=0
run_install() {
  local install_dir=$1
  shift
  OSV_SCANNER_PREFIX="$install_dir" \
    FAKE_CURL_LOG="${test_root}/curl.log" \
    PATH="${install_dir}:${fake_bin}:${PATH}" \
    "$@" \
    bash "${fixture}/scripts/install-osv-scanner.sh" 2>&1
}

install_dir="${test_root}/install"
mkdir -p "$install_dir"
: > "${test_root}/curl.log"
status=0
output=$(run_install "$install_dir" env) || status=$?
if [[ "$status" == 0 && "$output" == *"installed successfully"* ]] &&
  [[ -x "${install_dir}/osv-scanner" ]] &&
  [[ $("${install_dir}/osv-scanner" --version) == "osv-scanner version 2.5.0" ]] &&
  grep -Fq -- '--retry 5 --retry-all-errors --connect-timeout 20 --max-time 300' \
    "${test_root}/curl.log"; then
  printf 'ok   verified release installs with bounded curl settings\n'
else
  printf 'FAIL verified install: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

download_count=$(wc -l < "${test_root}/curl.log" | tr -d ' ')
status=0
output=$(run_install "$install_dir" env) || status=$?
after_count=$(wc -l < "${test_root}/curl.log" | tr -d ' ')
if [[ "$status" == 0 && "$output" == *"already installed"* &&
  "$download_count" == "$after_count" ]]; then
  printf 'ok   matching installed version skips downloads\n'
else
  printf 'FAIL existing install: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

explicit_dir="${test_root}/explicit"
mkdir -p "$explicit_dir"
status=0
output=$(OSV_SCANNER_PREFIX="$explicit_dir" \
  FAKE_CURL_LOG="${test_root}/curl.log" \
  PATH="${install_dir}:${explicit_dir}:${fake_bin}:${PATH}" \
  bash "${fixture}/scripts/install-osv-scanner.sh" 2>&1) || status=$?
if [[ "$status" == 0 && -x "${explicit_dir}/osv-scanner" ]] &&
  [[ $("${explicit_dir}/osv-scanner" --version) == "osv-scanner version 2.5.0" ]]; then
  printf 'ok   explicit prefix is not bypassed by a matching PATH binary\n'
else
  printf 'FAIL explicit prefix: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

mismatch_dir="${test_root}/mismatch"
mkdir -p "$mismatch_dir"
: > "${test_root}/curl.log"
status=0
output=$(run_install "$mismatch_dir" env FAKE_CHECKSUM_MODE=mismatch INSTALL_ATTEMPTS=2) || status=$?
attempts=$(grep -c 'osv-scanner_linux_amd64' "${test_root}/curl.log" || true)
if [[ "$status" == 1 && "$output" == *"after 2 attempts"* && "$attempts" == "2" &&
  ! -e "${mismatch_dir}/osv-scanner" ]]; then
  printf 'ok   checksum mismatch retries then fails without installing\n'
else
  printf 'FAIL checksum mismatch: exit %s, attempts %s\n%s\n' \
    "$status" "$attempts" "$output" >&2
  failures=$((failures + 1))
fi

missing_dir="${test_root}/missing"
mkdir -p "$missing_dir"
status=0
output=$(run_install "$missing_dir" env FAKE_CHECKSUM_MODE=missing INSTALL_ATTEMPTS=3) || status=$?
if [[ "$status" == 1 && "$output" == *"could not find checksum"* &&
  ! -e "${missing_dir}/osv-scanner" ]]; then
  printf 'ok   missing asset checksum fails immediately\n'
else
  printf 'FAIL missing checksum: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

wrong_version_dir="${test_root}/wrong-version"
mkdir -p "$wrong_version_dir"
printf '#!/usr/bin/env bash\necho "osv-scanner version 0.9.0"\n' \
  > "${wrong_version_dir}/osv-scanner"
chmod +x "${wrong_version_dir}/osv-scanner"
status=0
output=$(run_install "$wrong_version_dir" env FAKE_ASSET_VERSION=1.0.0) || status=$?
if [[ "$status" == 1 && "$output" == *"downloaded asset version mismatch"* ]] &&
  [[ $("${wrong_version_dir}/osv-scanner" --version) == "osv-scanner version 0.9.0" ]]; then
  printf 'ok   wrong asset version leaves the installed target unchanged\n'
else
  printf 'FAIL target version: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

for version in 2.5.0-alpha 2.5.0-beta.1 2.5.0-rc.1 2.5.0+local 2.5.0.1; do
  suffix_dir="${test_root}/$(printf '%s' "$version" | tr '.+' '--')"
  mkdir -p "$suffix_dir"
  printf '#!/usr/bin/env bash\necho "osv-scanner version 0.9.0"\n' \
    > "${suffix_dir}/osv-scanner"
  chmod +x "${suffix_dir}/osv-scanner"
  status=0
  output=$(run_install "$suffix_dir" env FAKE_ASSET_VERSION="$version") || status=$?
  if [[ "$status" == 1 && "$output" == *"downloaded asset version mismatch"* ]] &&
    [[ $("${suffix_dir}/osv-scanner" --version) == "osv-scanner version 0.9.0" ]]; then
    printf 'ok   asset version %s does not satisfy the stable pin\n' "$version"
  else
    printf 'FAIL asset version %s: exit %s\n%s\n' "$version" "$status" "$output" >&2
    failures=$((failures + 1))
  fi
done

relative_root="${test_root}/relative"
mkdir -p "$relative_root"
status=0
output=$(cd "$relative_root" &&
  OSV_SCANNER_PREFIX=relative-bin \
    FAKE_CURL_LOG="${test_root}/curl.log" \
    PATH="${relative_root}/relative-bin:${fake_bin}:${PATH}" \
    bash "${fixture}/scripts/install-osv-scanner.sh" 2>&1) || status=$?
if [[ "$status" == 0 && -x "${relative_root}/relative-bin/osv-scanner" ]]; then
  printf 'ok   relative install prefix resolves before temporary-directory use\n'
else
  printf 'FAIL relative prefix: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

cat > "${fake_bin}/mkdir" << 'FAKE_MKDIR'
#!/usr/bin/env bash
exit 0
FAKE_MKDIR
chmod +x "${fake_bin}/mkdir"
unresolved_dir="${test_root}/not-created"
status=0
output=$(run_install "$unresolved_dir" env) || status=$?
rm "${fake_bin}/mkdir"
if [[ "$status" == 1 && "$output" == *"could not create install directory: $unresolved_dir"* ]]; then
  printf 'ok   unresolved install directory reports the requested path\n'
else
  printf 'FAIL unresolved install directory: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

status=0
output=$(run_install "${test_root}/invalid" env INSTALL_ATTEMPTS=0) || status=$?
if [[ "$status" == 1 && "$output" == *"INSTALL_ATTEMPTS must be a positive integer"* ]]; then
  printf 'ok   invalid retry setting fails before download\n'
else
  printf 'FAIL invalid retry setting: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

status=0
output=$(run_install "${test_root}/unsupported" env FAKE_UNAME_S=Plan9) || status=$?
if [[ "$status" == 1 && "$output" == *"unsupported OS: Plan9"* ]]; then
  printf 'ok   unsupported operating system fails clearly\n'
else
  printf 'FAIL unsupported OS: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

shadow_bin="${test_root}/shadow"
shadow_dir="${test_root}/shadow-install"
mkdir -p "$shadow_bin" "$shadow_dir"
cat > "${shadow_bin}/osv-scanner" << 'SHADOW'
#!/usr/bin/env bash
echo "osv-scanner version 1.0.0"
SHADOW
chmod +x "${shadow_bin}/osv-scanner"
status=0
output=$(OSV_SCANNER_PREFIX="$shadow_dir" \
  FAKE_CURL_LOG="${test_root}/curl.log" \
  PATH="${shadow_bin}:${shadow_dir}:${fake_bin}:${PATH}" \
  bash "${fixture}/scripts/install-osv-scanner.sh" 2>&1) || status=$?
if [[ "$status" == 1 && "$output" == *"Another osv-scanner binary may be shadowing"* ]] &&
  [[ -x "${shadow_dir}/osv-scanner" ]]; then
  printf 'ok   shadowed installed binary is reported\n'
else
  printf 'FAIL shadowed binary: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

write_catalog 2.5.0-rc.1
: > "${test_root}/curl.log"
status=0
output=$(run_install "${test_root}/unstable-pin" env) || status=$?
if [[ "$status" == 1 &&
  "$output" == *"version pin must be a stable X.Y.Z release: 2.5.0-rc.1"* ]] &&
  [[ ! -s "${test_root}/curl.log" ]]; then
  printf 'ok   unstable catalog pin fails before download\n'
else
  printf 'FAIL unstable catalog pin: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

if ((failures > 0)); then
  printf '\n%s OSV installer test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nAll OSV installer tests passed\n'
