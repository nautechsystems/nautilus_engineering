# Nautilus Engineering

Nautilus Engineering provides shared engineering standards, lint configurations, pre-commit definitions, and
repository checks for Nautilus projects. Consumer repositories vendor selected files at a pinned commit. They
review each update locally and keep their own project policy.

The shared files define stable behavior that should stay consistent across projects. Release processes,
deployment logic, generated-file exceptions, compiler pins, and other repository-specific
decisions stay with each consumer.

## How shared changes reach a repository

1. Maintainers commit and test a shared change here.
1. A consumer vendors selected artifacts from that exact commit.
1. The sync command records the source revision, manifest hash, target paths, file hashes, and executable
   modes in `.nautilus-engineering.lock`.
1. The consumer reviews and tests the adoption as a normal repository change.

A commit here never changes a consumer by itself. Updates stay reproducible, and each repository adopts them
on its own schedule.

## Repository map

| Path          | Contents                                                                                  |
| ------------- | ----------------------------------------------------------------------------------------- |
| `standards/`  | Written standards for Markdown and shell scripts                                          |
| `config/`     | Configuration for markdownlint, rustfmt, yamllint, Taplo, Prettier, and npm-check-updates |
| `pre-commit/` | Repository entries rendered into managed consumer sections                                |
| `scripts/`    | Portable checks, version readers, installers, and dependency update tools                 |
| `scripts/ci/` | CI tool installation, lint commands, and companion tests                                  |
| `sync/`       | The artifact catalog, vendoring command, checker, and section renderer                    |
| `docs/`       | Consumer adoption and supply-chain security guides                                        |
| `tests/`      | Focused tests for shared behavior                                                         |

- [Markdown standard](standards/markdown.md): Markdown syntax and formatting.
- [Shell standard](standards/shell.md): shell selection, portability, failure handling, formatting, and testing.
- `config/` and `pre-commit/`: authoritative lint and formatting baselines for Markdown, Rust, shell, YAML, and TOML.

## Adopt shared files

- [Consumer adoption](docs/consumer-adoption.md): select profiles, make a first adoption,
  update an existing lock, and integrate the managed pre-commit section. It includes a phased path
  for established repositories such as NautilusTrader, where local hooks and target paths must
  remain intact.
- [Supply-chain security](docs/supply-chain-security.md): the shared scanner catalog,
  typed audit policy, installation path, and local and CI wiring for dependency security checks.

Before you commit a lock to a consumer, make its source revision available from the repository URL in
[`sync/manifest.toml`](sync/manifest.toml). The sync command reads committed content from the local source
checkout. It never fetches, commits, or pushes either repository.

## Ownership boundaries

Shared files provide a baseline rather than a complete repository policy:

- The shared catalog owns pins for tools used by multiple Nautilus repositories.
- Shared Cargo tools include Cargo Binstall, Cargo Fuzz, Cargo Hack, and Cargo Machete.
- Optional hook profiles cover spelling, secrets, commit messages, Dockerfiles, and Mermaid diagrams.
- Consumer `tools.toml` and Cargo metadata own pins for tools used by only that repository.
- JavaScript manifests and lockfiles own npm tool versions. Shared Prettier and npm-check-updates
  configurations define formatting and release-age policy.
- Consumer `rust-toolchain.toml` files keep independent compiler pins.
- Repository-specific pre-commit hooks, exclusions, and top-level settings remain outside the
  managed sections.
- Makefiles and workflows remain local and call shared scripts where the behavior is reusable.
- Advisory exceptions, generated-file rules, release jobs, and deployment policy remain local.

Consumers vendor configuration baselines as follows:

- Markdownlint and yamllint baselines can be vendored to another path and extended from the consumer's root
  configuration.
- Consumers synchronize the whole Taplo configuration file because Taplo does not support cross-file
  configuration inheritance.
- The Rust formatting baseline, `config/rustfmt.toml`, vendors to a Cargo repository's root by default.
- The JavaScript profile provides an opt-in Prettier baseline and a seven-day npm-check-updates cooldown.
  Consumer commands choose the update target, such as minor or latest.

The root `tools.toml` catalogs shared engineering tools and this repository's validation tools.
Consumers vendor it to `.nautilus-engineering/tools.toml`. CI reads its pins through the shared
version scripts, and `make check` verifies that matching pre-commit pins stay aligned.

## Maintainer checks

### Local validation

Run the complete local CI-readiness gate:

```bash
make pre-flight
```

`make pre-flight` checks all GitHub Action pins and release cooldowns before running `make pre-commit`.
`make pre-commit` runs each formatter, linter, and repository check, including private-key detection,
GitHub Action checks, and `make check`.

The Makefile runs the exact cataloged prek release through uv.
Install the pre-commit and pre-push hooks with `prek install`.

To run only syntax checks, tool-pin validation, and repository tests, use:

```bash
make check
```

Make keeps spaces in discovered filenames and stops if Git discovery fails.

To select files, set the matching variable on the `make` command line:

- **Python syntax checks**: `PYTHON_FILES`.
- **Shell syntax checks**: `SHELL_FILES`.
- **Tests**: `TEST_FILES`, as in `make test TEST_FILES=tests/test-sync.bash`.
- **GitHub Action checks**: `ACTION_FILES` with `make check-github-action-pins`.

Selections are shell-word lists: quote filenames containing spaces inside the value. Empty or malformed
explicit lists fail. The runner parses values without a shell after Make expands its own variable references
and functions.

`scripts/check-github-actions.sh` requires Bash, Git, curl, and jq. It checks:

- Source comments.
- Full commit SHAs that match the named release tags.
- A matching GitHub release whose `published_at` timestamp is at least 14 complete days old.

Missing or invalid publication metadata and failed lookups fail the check. Tag and commit dates do not
substitute for a release publication date.

CI and pre-push check all workflows and composite actions. The commit hook checks changed workflow and
composite Action files. Set `GITHUB_TOKEN` to authenticate release lookups. Public lookups also work
without a token, subject to GitHub's unauthenticated rate limit.

This repository has no dependency graph to audit. Its tests use controlled fixtures for the shared
supply-chain runner, installer, exact version checks, policy validation, and secondary dependency paths.

Each maintained script has behavioral coverage. CI runs each tracked `tests/test-*.bash` and
`scripts/ci/test-*.bash` file through `make check`. CI-specific shell stays in `scripts/ci/` so the shell
formatters and linters check it alongside shared scripts.

Consumer pre-flight targets run their own unit tests and configured dependency audits.

### Adoption status

To compare each consumer's lock revision with the source `HEAD` and list changed and unadopted artifacts, run:

```bash
make adoption-status CONSUMERS="../consumer-a ../consumer-b"
```

The report requires explicit consumer paths. It reads only locks and local Git history. It never changes a
consumer or scans neighboring directories.

### Tool updates

To find cataloged tool pins whose upstream has a newer release, run:

```bash
make check-tool-updates
```

`make outdated` is an alias. Each `tools.toml` entry declares:

- `releases`: the release source. `make check` verifies that every entry has this field.
- `kind`: `"python"` or `"tool"`, which selects the cooldown independently of the release source.

Scoped npm packages use `npm:@scope/name`, as in the Mermaid lint entry.

The report lists each pin with its kind, latest release, release UTC timestamp, and age.

**Cooldowns**:

- Python packages use 7 days.
- uv uses 7 days because its pin updates also change consumer Docker images.
- Other tools use 3 days.

Python packages appear as `python`. Native tools such as prek, ruff, and uv appear as `tool` even when
distributed through PyPI. To override both cooldown defaults, set `COOLDOWN_DAYS`.

When the latest release is still within its cooldown, subsequent rows list each newer release between the
pin and the latest release.

In a terminal, release colors show age:

- Red: less than a day old.
- Orange: at least a day old and still within the cooldown.
- Uncolored: older releases.

The summary sorts each pin that differs from its latest release into one group:

| Group         | Condition                                                              | Fails the check |
| ------------- | ---------------------------------------------------------------------- | --------------- |
| Upgradable    | A release newer than the pin is past the cooldown                      | Yes             |
| Cooldown hold | The latest release is within the cooldown, and no newer one is past it | No              |
| Pin mismatch  | The latest release is past the cooldown but not newer than the pin     | Yes             |

An upgradable pin's target is the **newest release past the cooldown**. This target can be older than the
latest release. Invalid catalog entries and failed release or upgrade-target lookups also fail the check.

Update a pin here first. Consumers adopt the reviewed commit.

### CI validation

CI runs on Linux and macOS, the supported development and validation platforms for this repository. Shared
scripts remain portable for downstream use on Linux, macOS, and Windows through Git Bash or MSYS2. This
repository does not validate Windows development.

- Linux and macOS run the functional checks, repository tests, and tool catalog validation against its
  pre-commit and workflow consumers.
- Linux also runs the shell, Python, YAML, Markdown, and TOML linters. It checks each GitHub Action reference
  for a source comment, a full commit SHA that matches its named release tag, and a release published at least
  14 complete days ago.

## License

This repository is licensed under the GNU Lesser General Public License v3.0 or later. See
[`LICENSE`](LICENSE).
