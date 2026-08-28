# Centralize Supply-Chain Security

Nautilus repositories use the same pinned scanners and audit runner while retaining their own
dependency scope, advisory exceptions, and enforcement choices. This separates shared machinery
from repository policy.

## Ownership

| Concern                             | Owner                | Source                                          |
| ----------------------------------- | -------------------- | ----------------------------------------------- |
| Shared tool versions                | Nautilus Engineering | `.nautilus-engineering/tools.toml`              |
| Audit command construction          | Nautilus Engineering | `scripts/security-audit.py`                     |
| Cargo and OSV Scanner installation  | Nautilus Engineering | `scripts/install-security-tools.sh`             |
| Dependency surfaces and enforcement | Consumer repository  | `security-audit.toml`                           |
| Advisory exceptions                 | Consumer repository  | `security-audit.toml` and scanner configuration |
| License, source, and package policy | Consumer repository  | `deny.toml` and cargo-vet supply-chain files    |
| Local and CI entry points           | Consumer repository  | `Makefile` and workflow files                   |
| Tools used by only one repository   | Consumer repository  | Local `tools.toml` or Cargo workspace metadata  |

The shared version readers use `.nautilus-engineering/tools.toml` first, then a consumer-local
catalog for tools that are not shared. They fail if both catalogs define the same tool. This keeps
one release decision for shared tools without absorbing repository-specific tools.

## Configure a consumer

Create `security-audit.toml` at the repository root. Every dependency surface is explicit. Paths
must exist, use POSIX separators, and stay within the repository. Unknown fields and unsupported
values fail validation.

```toml
version = 1

[[cargo.audit]]
lockfile = "Cargo.lock"
ignore = ["RUSTSEC-2026-0001"]
deny = ["warnings"]
report = false

[[cargo.deny]]
manifest = "Cargo.toml"
config = "deny.toml"
all-features = true
checks = ["advisories", "licenses", "sources", "bans"]

[[cargo.vet]]
manifest = "Cargo.toml"
store = "supply-chain"

[[python]]
project = "python"
python = "3.12"
all-extras = true
all-groups = true
ignore-vulns = ["PYSEC-2026-0001"]

[[node]]
project = "docs"
production = true
full = "report"
signatures = true

[osv]
config = "osv-scanner.toml"
lockfiles = ["Cargo.lock", "python/uv.lock", "docs/package-lock.json"]
report = false
```

Add another array entry for a secondary Cargo workspace, Python project, or Node project. A Cargo
fuzz workspace can therefore name its own manifest, lockfile, deny configuration, and cargo-vet
store without adding special cases to the shared runner.

### Cargo audit

Each `[[cargo.audit]]` entry requires `lockfile`. The optional `ignore` array accepts RustSec
advisory IDs. The optional `deny` array accepts `warnings`, `unmaintained`, `unsound`, and `yanked`.
Set `report = true` to print successful scanner output; findings still fail the audit.

### Cargo deny

Each `[[cargo.deny]]` entry requires `manifest`. The optional fields are `config`, `all-features`,
and `checks`. Checks default to `advisories`, `licenses`, `sources`, and `bans`. The runner always
uses `--locked`, so stale dependency resolution fails instead of changing the Cargo lockfile.

### Cargo vet

Each `[[cargo.vet]]` entry requires `manifest`. Set `store` when the supply-chain directory is not
the default for that workspace. The runner always uses `--locked`, so missing or inconsistent local
imported-audit state fails. Refresh and review remote imports outside the audit gate.

### Python

Each `[[python]]` entry requires `project` and a `python` major and minor version. Select all extras
with `all-extras`. Select all dependency groups with `all-groups`, or name individual `groups`, but
do not use both. `ignore-vulns` records repository-owned pip-audit exceptions.

The runner exports the frozen uv resolution without local project, workspace, or path packages,
then invokes the exact central `pip-audit` version in an isolated uv environment. It enables hash
checking and disables pip resolution so the audit covers the locked third-party dependency set.

### Node

Each `[[node]]` entry requires `project`. `production = true` gates on `npm audit --omit=dev`.
`full` accepts:

- `off`: skip the full dependency tree.
- `report`: show full-tree findings without failing the run.
- `gate`: fail on full-tree findings.

`signatures = true` gates on registry signatures. The signature command sets its release-age floor
to zero because it re-resolves package metadata; installation cooldown remains a consumer policy.
Each Node entry must enable production, full-tree, or signature auditing.

### OSV Scanner

The `[osv]` table requires one or more `lockfiles` and accepts an optional `config`. Set
`report = true` to print successful scanner output. Findings still fail the audit.

## Install and verify tools

Install the central Cargo scanner versions and OSV Scanner with:

```bash
bash scripts/install-security-tools.sh
```

The installer skips matching versions, installs stale or missing Cargo tools with exact versions,
uses the checksummed OSV Scanner release installer, and verifies installed versions before it
returns. Install the central uv version through the consumer's existing uv bootstrap. Node and npm
remain part of the consumer's runtime toolchain.

Validate policy without requiring scanners:

```bash
python3 scripts/security-audit.py validate
```

Check installed scanner versions without auditing dependencies:

```bash
python3 scripts/security-audit.py check-tools
```

Run every configured dependency audit:

```bash
python3 scripts/security-audit.py run
```

Tool checks run before dependency commands. A missing or stale scanner stops the run before it can
produce results from a different scanner release. Audit commands capture successful output and
show it only for configured reports. Failures show their captured output, and the runner continues
through the remaining dependency surfaces before returning a failing status.

## Use one entry point locally and in CI

Keep the repository's Makefile and workflow local. Both should call the same shared runner:

```makefile
.PHONY: check-security-tools security-audit

check-security-tools: ; python3 scripts/security-audit.py check-tools

security-audit: ; python3 scripts/security-audit.py run
```

Add `security-audit` and the repository's unit tests to its pre-flight target. CI should invoke that
target or `python3 scripts/security-audit.py run` directly. Do not reconstruct scanner commands in
the workflow because that creates a second policy path.

## Update shared releases

Update a shared version once in Nautilus Engineering, validate its release and command-line
compatibility, run this repository's pre-flight gate, and commit the reviewed candidate. Consumers
then update their vendored artifacts and lock to that exact engineering commit. A shared commit
does not change a consumer until its own adoption is reviewed and committed.
