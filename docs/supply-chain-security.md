# Centralize Supply-Chain Security

Nautilus repositories use the same pinned scanners and audit runner. Each repository keeps its own dependency
scope, advisory exceptions, and enforcement choices.

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

The shared version readers use `.nautilus-engineering/tools.toml` first, then a consumer-local catalog for
tools that are not shared. They fail if both catalogs define the same tool. This keeps shared release
decisions central while consumers control repository-specific tools.

## Configure a consumer

First, [adopt the `security` profile](consumer-adoption.md) to copy the shared tool catalog, audit runner,
version readers, and scanner installers into the consumer. Run this guide's commands from the consumer root.

Create `security-audit.toml` at that root and list each dependency surface explicitly:

- Paths must exist, use POSIX separators, and stay within the repository.
- Unknown fields and unsupported values fail validation.

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

For a secondary Cargo workspace, Python project, or Node project, add another array entry. For example, a
Cargo fuzz workspace can name its own manifest, lockfile, deny configuration, and cargo-vet store without
special cases in the shared runner.

### Cargo audit

Each `[[cargo.audit]]` entry requires `lockfile`. These arrays are optional:

- `ignore`: RustSec advisory IDs.
- `deny`: `warnings`, `unmaintained`, `unsound`, and `yanked`.

To print successful scanner output, set `report = true`. Findings still fail the audit.

### Cargo deny

Each `[[cargo.deny]]` entry requires `manifest`. Optional fields are `config`, `all-features`, and
`checks`. Checks default to `advisories`, `licenses`, `sources`, and `bans`.

The runner always uses `--locked`. Stale dependency resolution fails and does not change the Cargo lockfile.

### Cargo vet

Each `[[cargo.vet]]` entry requires `manifest`. Set `store` when the supply-chain directory is not the
default for that workspace.

The runner always uses `--locked`. Missing or inconsistent local imported-audit state fails. Refresh and
review remote imports outside the audit gate.

### Python

Each `[[python]]` entry requires `project` and a `python` major and minor version. Optional fields:

- `all-extras`: select all extras.
- `all-groups` or `groups`: select all dependency groups or name individual groups. Do not use both.
- `ignore-vulns`: repository-owned pip-audit exceptions.

The audit covers the locked third-party dependency set. The runner exports the frozen uv resolution without
local project, workspace, or path packages. It then runs the exact central `pip-audit` version in an isolated
uv environment with hash checking enabled and pip resolution disabled.

The Python audit uses a 30-second socket timeout and retries PyPI connection timeouts up to three times
without delay. Vulnerability findings and other errors fail immediately.

### Node

Each `[[node]]` entry requires `project`. `production = true` gates on `npm audit --omit=dev`.
`full` accepts:

- `off`: skip the full dependency tree.
- `report`: show full-tree findings without failing the run.
- `gate`: fail on full-tree findings.

`signatures = true` gates on registry signatures. The signature command sets its release-age floor to zero
because it re-resolves package metadata. The consumer still controls the installation cooldown.

Each Node entry **must enable production, full-tree, or signature auditing**.

### OSV Scanner

The `[osv]` table requires one or more `lockfiles` and accepts an optional `config`. Set
`report = true` to print successful scanner output. Findings still fail the audit.

## Install and verify tools

Install the central Cargo scanner versions and OSV Scanner with:

```bash
bash scripts/install-security-tools.sh
```

The installer:

- Skips matching versions.
- Installs stale or missing Cargo tools with exact versions.
- Uses the checksummed OSV Scanner release installer.
- Verifies installed versions before it returns.

Install the central uv version through the consumer's existing uv bootstrap. Node and npm remain part
of the consumer's runtime toolchain.

Validate policy without requiring scanners:

```bash
python3 scripts/security-audit.py validate
```

Check installed scanner versions without auditing dependencies:

```bash
python3 scripts/security-audit.py check-tools
```

Run each configured dependency audit:

```bash
python3 scripts/security-audit.py run
```

**Version gate**: Tool checks run before dependency commands. A missing or stale scanner stops the run before
it can produce results from a different scanner release.

**Audit results**:

- Commands show captured successful output only for configured reports.
- Failures show their captured output.
- After a failure, the runner checks the remaining dependency surfaces before returning a failing status.

## Use one entry point locally and in CI

Keep the repository's Makefile and workflow local. Both should call the same shared runner:

```makefile
.PHONY: check-security-tools security-audit

check-security-tools: ; python3 scripts/security-audit.py check-tools

security-audit: ; python3 scripts/security-audit.py run
```

Add `security-audit` and the repository's unit tests to its pre-flight target. CI should invoke that target or
`python3 scripts/security-audit.py run` directly. Do not reconstruct scanner commands in the workflow.
Duplicate commands create a second policy path.

## Update shared releases

In Nautilus Engineering:

1. Update the shared version once.
1. Validate its release and command-line compatibility.
1. Run this repository's pre-flight gate.
1. Commit the reviewed candidate.

Consumers then update their vendored artifacts and lock to that exact engineering commit. A shared
commit does not change a consumer until its own adoption is reviewed and committed.
