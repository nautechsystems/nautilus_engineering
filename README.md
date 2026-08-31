# Nautilus Engineering

Nautilus Engineering is the maintained source for engineering standards, lint configurations,
pre-commit definitions, and repository checks shared across Nautilus projects. Consumer
repositories vendor selected files at a pinned commit, review each update locally, and retain their
own project policy.

Its scope is stable behavior that should stay consistent across projects. Release processes,
deployment logic, generated-file exceptions, compiler pins, and other repository-specific
decisions stay with each consumer.

## How shared changes reach a repository

1. A shared change is committed and tested here.
1. A consumer vendors selected artifacts from that exact commit.
1. The sync command records the source revision, manifest hash, target paths, file hashes, and
   executable modes in `.nautilus-engineering.lock`.
1. The consumer reviews and tests the adoption as a normal repository change.

A commit here never changes a consumer by itself. This separation keeps updates reproducible and
lets each repository adopt them on its own schedule.

## Repository map

| Path          | Contents                                                                  |
| ------------- | ------------------------------------------------------------------------- |
| `standards/`  | Written standards for Markdown and shell scripts                          |
| `config/`     | Baseline configuration for markdownlint, rustfmt, yamllint, and Taplo     |
| `pre-commit/` | Repository entries rendered into managed consumer sections                |
| `scripts/`    | Portable checks, version readers, installers, and dependency update tools |
| `sync/`       | The artifact catalog, vendoring command, checker, and section renderer    |
| `tests/`      | Focused tests for shared behavior                                         |

[`standards/markdown.md`](standards/markdown.md) defines the Markdown syntax and formatting rules.
[`standards/shell.md`](standards/shell.md) defines shell selection, portability, failure handling,
formatting, and testing. The files under `config/` and `pre-commit/` provide the authoritative lint
and formatting baselines for Markdown, Rust, shell, YAML, and TOML.

## Adopt shared files

Use [`docs/consumer-adoption.md`](docs/consumer-adoption.md) to select profiles, make a first
adoption, update an existing lock, and integrate the managed pre-commit section. The guide includes
a phased path for established repositories such as NautilusTrader, where local hooks and target
paths must remain intact.

[`docs/supply-chain-security.md`](docs/supply-chain-security.md) defines the shared scanner catalog,
typed audit policy, installation path, and local and CI wiring for dependency security checks.

The source revision must be available from the repository URL in
[`sync/manifest.toml`](sync/manifest.toml) before its lock is committed to a consumer. The sync
command reads committed content from the local source checkout; it does not fetch, commit, or push
either repository.

## Ownership boundaries

Shared files provide a baseline rather than a complete repository policy:

- The shared catalog owns pins for tools used by multiple Nautilus repositories.
- Consumer `tools.toml` and Cargo metadata own pins for tools used by only that repository.
- Consumer `rust-toolchain.toml` files keep independent compiler pins.
- Repository-specific pre-commit hooks, exclusions, and top-level settings remain outside the
  managed sections.
- Makefiles and workflows remain local and call shared scripts where the behavior is reusable.
- Advisory exceptions, generated-file rules, release jobs, and deployment policy remain local.

Markdownlint and yamllint baselines can be vendored to another path and extended from a consumer's
root configuration. Taplo configuration is synchronized as a whole file because Taplo does not
support cross-file configuration inheritance. The shared Rust formatting baseline lives in
`config/rustfmt.toml` and vendors to a Cargo repository's root by default.

The root `tools.toml` catalogs shared engineering tools and this repository's validation tools.
Consumers vendor it to `.nautilus-engineering/tools.toml`. CI reads its pins through the shared
version scripts, and `make check` verifies that matching pre-commit pins stay aligned.

## Maintainer checks

### Local validation

Run the complete local CI-readiness gate, including all repository tests, formatters, linters,
repository checks, private-key detection, and GitHub Action pin validation with:

```bash
make pre-flight
```

Run syntax checks, tool-pin validation, and focused tests with:

```bash
make check
```

Install the local hooks with `prek install`. Run every formatter, linter, and repository check with:

```bash
make pre-commit
```

The Makefile runs the exact cataloged prek release through uv. Nautilus Engineering has no
dependency graph to audit. Its test suite instead exercises the shared supply-chain runner,
installer, exact version checks, policy validation, and secondary dependency paths with controlled
fixtures. Every maintained script has behavioral coverage, and CI runs every tracked
`tests/test-*.bash` file. Consumer pre-flight targets run their own unit tests and configured
dependency audits.

### CI validation

CI runs the functional checks on Linux and macOS. These are the supported development and validation
platforms for this repository. Shared scripts remain portable for downstream use on Linux, macOS,
and Windows through Git Bash or MSYS2, but this repository does not validate Windows development.
Linux also runs the shell, Python, YAML, Markdown, and TOML linters. CI also validates the central
tool catalog against its pre-commit and workflow consumers. GitHub Action references are checked for
source comments and full commit SHAs that match their named release tags.

## License

This repository is licensed under the GNU Lesser General Public License v3.0 or later. See
[`LICENSE`](LICENSE).
