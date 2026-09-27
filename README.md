# Nautilus Engineering

Nautilus Engineering is the maintained source for engineering standards, lint configurations,
pre-commit definitions, and repository checks shared across Nautilus projects. Consumer
repositories vendor selected files at a pinned commit, review each update locally, and keep their
own project policy.

It covers stable behavior that should stay consistent across projects. Release processes,
deployment logic, generated-file exceptions, compiler pins, and other repository-specific
decisions stay with each consumer.

## How shared changes reach a repository

1. A shared change is committed and tested here.
1. A consumer vendors selected artifacts from that exact commit.
1. The sync command records the source revision, manifest hash, target paths, file hashes, and
   executable modes in `.nautilus-engineering.lock`.
1. The consumer reviews and tests the adoption as a normal repository change.

A commit here never changes a consumer by itself, so updates stay reproducible and each repository
adopts them on its own schedule.

## Repository map

| Path          | Contents                                                                  |
| ------------- | ------------------------------------------------------------------------- |
| `standards/`  | Written standards for Markdown and shell scripts                          |
| `config/`     | Baseline configuration for markdownlint, rustfmt, yamllint, and Taplo     |
| `pre-commit/` | Repository entries rendered into managed consumer sections                |
| `scripts/`    | Portable checks, version readers, installers, and dependency update tools |
| `sync/`       | The artifact catalog, vendoring command, checker, and section renderer    |
| `docs/`       | Consumer adoption and supply-chain security guides                        |
| `tests/`      | Focused tests for shared behavior                                         |

[`standards/markdown.md`](standards/markdown.md) defines Markdown syntax and formatting.
[`standards/shell.md`](standards/shell.md) defines shell selection, portability, failure handling,
formatting, and testing. The files under `config/` and `pre-commit/` are the authoritative lint and
formatting baselines for Markdown, Rust, shell, YAML, and TOML.

## Adopt shared files

- [`docs/consumer-adoption.md`](docs/consumer-adoption.md): select profiles, make a first adoption,
  update an existing lock, and integrate the managed pre-commit section. It includes a phased path
  for established repositories such as NautilusTrader, where local hooks and target paths must
  remain intact.
- [`docs/supply-chain-security.md`](docs/supply-chain-security.md): the shared scanner catalog,
  typed audit policy, installation path, and local and CI wiring for dependency security checks.

Before committing a lock to a consumer, make its source revision available from the repository URL
in [`sync/manifest.toml`](sync/manifest.toml). The sync command reads committed content from the
local source checkout and never fetches, commits, or pushes either repository.

## Ownership boundaries

Shared files provide a baseline rather than a complete repository policy:

- The shared catalog owns pins for tools used by multiple Nautilus repositories.
- Consumer `tools.toml` and Cargo metadata own pins for tools used by only that repository.
- Consumer `rust-toolchain.toml` files keep independent compiler pins.
- Repository-specific pre-commit hooks, exclusions, and top-level settings remain outside the
  managed sections.
- Makefiles and workflows remain local and call shared scripts where the behavior is reusable.
- Advisory exceptions, generated-file rules, release jobs, and deployment policy remain local.

Configuration baselines vendor as follows:

- Markdownlint and yamllint baselines can be vendored to another path and extended from the
  consumer's root configuration.
- Taplo configuration is synchronized as a whole file because Taplo does not support cross-file
  configuration inheritance.
- The Rust formatting baseline, `config/rustfmt.toml`, vendors to a Cargo repository's root by
  default.

The root `tools.toml` catalogs shared engineering tools and this repository's validation tools.
Consumers vendor it to `.nautilus-engineering/tools.toml`. CI reads its pins through the shared
version scripts, and `make check` verifies that matching pre-commit pins stay aligned.

## Maintainer checks

### Local validation

Run the complete local CI-readiness gate:

```bash
make pre-flight
```

`make pre-flight` is an alias for `make pre-commit`, which runs every formatter, linter, and
repository check, including private-key detection, GitHub Action pin validation, and `make check`.
The Makefile runs the exact cataloged prek release through uv. Install the hooks with
`prek install`.

For a faster loop, run only the syntax checks, tool-pin validation, and repository tests:

```bash
make check
```

This repository has no dependency graph to audit. Its tests instead exercise the shared
supply-chain runner, installer, exact version checks, policy validation, and secondary dependency
paths with controlled fixtures. Every maintained script has behavioral coverage, and CI runs every
tracked `tests/test-*.bash` file. Consumer pre-flight targets run their own unit tests and
configured dependency audits.

### Adoption status

To compare each consumer's lock revision with the current source `HEAD`, including its changed and
unadopted artifacts, run:

```bash
make adoption-status CONSUMERS="../consumer-a ../consumer-b"
```

The report requires explicit consumer paths. It reads only locks and local Git history, never
changes a consumer, and never scans neighboring directories.

### Tool updates

To find cataloged tool pins whose upstream has a newer release, run:

```bash
make check-tool-updates
```

`make outdated` is an alias. Each `tools.toml` entry names its release source in `releases`, and
`make check` verifies that the field stays complete.

The report lists each pin with its latest release, the release's UTC timestamp, and its age. The
cooldown defaults to 3 days; set `COOLDOWN_DAYS` to change it. When the latest release is still
within the cooldown, following rows list every newer release between the pin and latest. In a
terminal, releases less than a day old are red, releases still within the cooldown are orange, and
older releases are uncolored.

The summary sorts each pin that differs from its latest release into one group:

| Group         | Condition                                                              | Fails the check |
| ------------- | ---------------------------------------------------------------------- | --------------- |
| Upgradable    | A release newer than the pin is past the cooldown                      | Yes             |
| Cooldown hold | The latest release is within the cooldown, and no newer one is past it | No              |
| Pin mismatch  | The latest release is past the cooldown but not newer than the pin     | Yes             |

An upgradable pin's target is the newest release past the cooldown, which can be older than the
latest release. Invalid catalog entries and failed release or upgrade-target lookups also fail the
check. Update a pin here first; consumers adopt the reviewed commit.

### CI validation

CI runs on Linux and macOS, the supported development and validation platforms for this
repository. Shared scripts remain portable for downstream use on Linux, macOS, and Windows through
Git Bash or MSYS2, but this repository does not validate Windows development.

- Linux and macOS run the functional checks, repository tests, and tool catalog validation against
  its pre-commit and workflow consumers.
- Linux also runs the shell, Python, YAML, Markdown, and TOML linters, and checks that each GitHub
  Action reference has a source comment and a full commit SHA that matches its named release tag.

## License

This repository is licensed under the GNU Lesser General Public License v3.0 or later. See
[`LICENSE`](LICENSE).
