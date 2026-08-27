# Nautilus Engineering

Nautilus Engineering is the maintained source for engineering standards, lint configurations,
pre-commit definitions, and repository checks shared across Nautilus projects. Consumer
repositories vendor selected files at a pinned commit, review each update locally, and retain their
own project policy.

Its scope is stable behavior that should stay consistent across projects. Release processes,
deployment logic, generated-file exceptions, toolchain pins, and other repository-specific
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
| `standards/`  | Written standards, including the shared Markdown baseline                 |
| `config/`     | Baseline configuration for markdownlint, yamllint, and Taplo              |
| `pre-commit/` | Repository entries rendered into a managed consumer section               |
| `scripts/`    | Portable checks, version readers, installers, and dependency update tools |
| `sync/`       | The artifact catalog, vendoring command, checker, and section renderer    |
| `tests/`      | Focused tests for shared behavior                                         |

[`standards/markdown.md`](standards/markdown.md) defines the Markdown syntax and formatting rules. It
uses CommonMark as its base and GitHub Flavored Markdown for documented extensions. The files under
`config/` are the authoritative lint and formatting baselines for Markdown, YAML, and TOML.

## Adopt shared files

Use [`docs/consumer-adoption.md`](docs/consumer-adoption.md) to select profiles, make a first
adoption, update an existing lock, and integrate the managed pre-commit section. The guide includes
a phased path for established repositories such as NautilusTrader, where local hooks and target
paths must remain intact.

The source revision must be available from the repository URL in
[`sync/manifest.toml`](sync/manifest.toml) before its lock is committed to a consumer. The sync
command reads committed content from the local source checkout; it does not fetch, commit, or push
either repository.

## Ownership boundaries

Shared files provide a baseline rather than a complete repository policy:

- Consumer `tools.toml` files keep independent tool pins and release timing.
- Consumer `rust-toolchain.toml` and Cargo metadata keep independent compiler and Cargo tool pins.
- Repository-specific pre-commit hooks, exclusions, and top-level settings remain outside the
  managed section.
- Makefiles and workflows remain local and call shared scripts where the behavior is reusable.
- Advisory exceptions, generated-file rules, release jobs, and deployment policy remain local.

Markdownlint and yamllint baselines can be vendored to another path and extended from a consumer's
root configuration. Taplo configuration is synchronized as a whole file because Taplo does not
support cross-file configuration inheritance.

The root `tools.toml` catalogs the tools used to validate this repository. CI reads those pins
through `scripts/tool-version.sh`, and `make check` verifies that matching pre-commit revisions stay
aligned. This catalog is not a consumer artifact.

## Maintainer checks

Run syntax checks, tool-pin validation, and focused tests with:

```bash
make check
```

Install the local hooks with `prek install`. Run every formatter, linter, and repository check with:

```bash
make pre-commit
```

These commands validate this repository; they do not run consumer test suites.

CI runs the functional checks on Linux, macOS, and Windows. Linux also runs the shell, Python, YAML,
Markdown, and TOML linters. GitHub Action references are checked for source comments and full commit
SHAs that match their named release tags.

## License

This repository is licensed under the GNU Lesser General Public License v3.0 or later. See
[`LICENSE`](LICENSE).
