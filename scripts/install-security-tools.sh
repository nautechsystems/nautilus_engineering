#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v cargo > /dev/null 2>&1; then
  echo "Error: cargo is required to install the Cargo supply-chain tools" >&2
  exit 1
fi

installed_version() {
  local subcommand=$1

  cargo "$subcommand" --version 2> /dev/null |
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+' |
    head -1 || true
}

install_cargo_tool() {
  local package=$1 subcommand=$2 required current

  required=$(bash "$SCRIPT_DIR/cargo-tool-version.sh" "$package")
  current=$(installed_version "$subcommand")
  if [[ "$current" == "$required" ]]; then
    printf '%s %s is already installed\n' "$package" "$required"
    return
  fi

  if [[ -n "$current" ]]; then
    printf 'Updating %s from %s to %s\n' "$package" "$current" "$required"
  else
    printf 'Installing %s %s\n' "$package" "$required"
  fi
  cargo install "$package" --version "$required" --locked --force

  current=$(installed_version "$subcommand")
  if [[ "$current" != "$required" ]]; then
    printf 'Error: %s version mismatch after install: expected %s, found %s\n' \
      "$package" "$required" "${current:-not installed}" >&2
    exit 1
  fi
}

install_cargo_tool cargo-audit audit
install_cargo_tool cargo-deny deny
install_cargo_tool cargo-vet vet
bash "$SCRIPT_DIR/install-osv-scanner.sh"

required_osv=$(bash "$SCRIPT_DIR/tool-version.sh" osv-scanner)
if ! command -v osv-scanner > /dev/null 2>&1; then
  echo "Error: osv-scanner was installed outside PATH" >&2
  exit 1
fi
installed_osv=$(osv-scanner --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [[ "$installed_osv" != "$required_osv" ]]; then
  printf 'Error: osv-scanner version mismatch after install: expected %s, found %s\n' \
    "$required_osv" "${installed_osv:-not installed}" >&2
  exit 1
fi

echo "All shared supply-chain tools are installed at their central versions"
