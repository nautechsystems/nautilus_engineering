#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 || ("$1" != shell && "$1" != config) ]]; then
  echo 'Usage: install-tools.bash {shell|config}' >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
cd "$repo_root"

case "$1" in
  shell)
    : "${RUNNER_TEMP:?RUNNER_TEMP is required for the shfmt install directory}"
    shellcheck_version=$(bash scripts/tool-version.sh shellcheck)
    shfmt_version=$(bash scripts/tool-version.sh shfmt)
    python -m pip install "shellcheck-py==$shellcheck_version"
    GOBIN="${RUNNER_TEMP}/bin" go install "mvdan.cc/sh/v3/cmd/shfmt@v$shfmt_version"
    ;;
  config)
    prek_version=$(bash scripts/tool-version.sh prek)
    ruff_version=$(bash scripts/tool-version.sh ruff)
    yamllint_version=$(bash scripts/tool-version.sh yamllint)
    taplo_version=$(bash scripts/tool-version.sh taplo)
    python -m pip install \
      "prek==$prek_version" \
      "ruff==$ruff_version" \
      "yamllint==$yamllint_version"

    # Limit CPU use when this installer runs on a shared machine
    CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}" \
      cargo install taplo-cli --version "$taplo_version" --locked
    ;;
esac
