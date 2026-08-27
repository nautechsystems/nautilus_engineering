# Nautilus Engineering

`nautilus_engineering` is the maintained source for engineering standards and repository support
that should stay consistent across Nautilus repositories.

The repository separates shared policy from repository-specific policy. It does not replace local
configuration where a repository needs different paths, exclusions, generated-file handling, or
language-specific hooks.

## Repository contents

- `standards/` contains shared written standards, including the Markdown standard.
- `config/` contains authoritative baseline configurations for markdownlint, yamllint, and Taplo.
- `pre-commit/` contains reusable YAML entries for stable shared hooks.
- `scripts/` contains portable repository checks and install scripts.
- `sync/` contains the artifact catalog and the vendoring command.
- `tests/` contains focused tests for shared behavior.

## Authority and adoption

Changes land here before they are adopted by consumer repositories. Adoption is a separate,
reviewable change in each consumer. This keeps a central edit from changing every repository at
once and lets each repository retain local policy around the shared baseline.

Do not commit a consumer lock until the manifest repository URL resolves to a repository that
contains its pinned revision. A local-only source checkout does not give other contributors or CI a
way to reproduce an adoption.

## Shared standards and configuration

[`standards/markdown.md`](standards/markdown.md) defines the common Markdown baseline. It uses
CommonMark as the base specification, GitHub Flavored Markdown for documented extensions, and the
repository's markdownlint configuration for mechanical enforcement.

The files under `config/` are authoritative baselines:

- `markdownlint.jsonc` defines the shared Markdown rules.
- `yamllint.yaml` defines the shared YAML rules.
- `taplo.toml` defines the shared TOML formatting rules.

A consumer with no local exception can vendor a configuration at its usual root path. A consumer
that needs local markdownlint or yamllint policy can vendor the baseline elsewhere with `--target`
and extend it from its root configuration. Taplo configuration is synchronized as a whole file
because Taplo does not provide cross-file configuration inheritance.

## Pre-commit definitions

The YAML files under `pre-commit/` contain complete repository entries for the shared shell, YAML,
TOML, and Markdown hooks. Pre-commit and prek do not include entries from other configuration files,
so these definitions are inputs to a managed section in each consumer's `repos` list. Repository
exclusions and local hooks remain outside that section.

The pre-commit profile vendors these definitions and the managed-section command. It does not
rewrite a consumer's `.pre-commit-config.yaml` during vendoring because that changes an existing
configuration layout. After reviewing the selected definitions, render the section with:

```bash
python3 scripts/manage-nautilus-engineering-pre-commit.py render
```

Rendering absorbs byte-identical unmanaged copies of selected definitions and stops when a local
variant has the same repository or hook identity. Leave that variant unselected or reconcile its
repository-specific policy before rendering. The shared sync definition installs unconditional
staged checks for both the lock and the rendered section.

## Vendoring shared files

The sync command copies files from a committed `nautilus_engineering` revision and records their
content hashes in `.nautilus-engineering.lock` in the consumer repository. It never fetches,
commits, or pushes a consumer repository.

After this repository has an initial commit, list the available artifacts and profiles with:

```bash
sync/sync.bash list
```

Vendor a profile into a local consumer checkout with:

```bash
sync/sync.bash vendor --consumer ../consumer_repository --profile markdown
```

Update an existing consumer without restating its adoption choices with:

```bash
sync/sync.bash update --consumer ../consumer_repository
```

The update command reads the current lock and preserves its complete artifact set, recorded
profiles, and target paths. New artifacts added to a selected profile remain unadopted until an
explicit `vendor` selection or `update --add`. Update stops if the current manifest no longer
contains a locked artifact.

Add one artifact to an existing adoption without restating the locked selection with:

```bash
sync/sync.bash update \
  --consumer ../consumer_repository \
  --add github-action-pin-check \
  --target github-action-pin-check=scripts/ci/check-github-action-shas.sh
```

Use `--target ARTIFACT=PATH` when a repository needs to store a shared base at a different path and
extend it from local configuration. Run the vendored checker in worktree mode during development
or with `--staged` from pre-commit. Artifacts marked `target_fixed = true` reject target overrides
because other managed files refer to their manifest paths.

Vendoring rejects absolute paths, parent traversal, symlink traversal, Windows path aliases,
special-file targets, duplicate targets, and uncommitted source artifacts. It stages the selected
content in the consumer before replacing managed files. The lock file is replaced last. During
replacement, prior files and the old lock remain under the temporary directory named in
`.nautilus-engineering.syncing`. The command restores them after an ordinary error or handled
interrupt. An abrupt process interruption leaves the marker, process lock, and readable backups for
manual recovery. The checker fails while either the marker or process lock remains.

The lock and checker detect accidental drift. They are not a security boundary because a consumer
change can modify both a managed file and its lock. A modified checker can also disable its own
verification, so review checker and lock changes together. The sync command assumes no hostile
concurrent filesystem changes. Its marker and replacement order do not provide database-style
durability across power loss or filesystem failure.

Consumer repositories must retain LF line endings for vendored text files. The staged checker reads
Git blobs and enforces executable modes on every platform. Worktree mode skips mode checks on Git
Bash because Windows filesystems do not expose the Git executable bit reliably, and reports that
limitation in its success message.

The sync command does not delete paths removed from a selection. It reports previously managed
paths, leaves them unchanged, and removes them from the new lock. Deletion requires a separate,
reviewed consumer change.

## Validation

Run the focused repository checks with:

```bash
make check
```

The check runs syntax checks and every focused test in this repository. It does not run consumer
repository test suites. CI runs the same functional checks on Linux, macOS, and Windows, then runs
shell, YAML, Markdown, and TOML lint on Linux. CI also checks that each external GitHub Action has
its source URL immediately above `uses:` and that its full commit SHA matches the named release tag.

## License

This repository is licensed under the GNU Lesser General Public License v3.0 or later. See
[`LICENSE`](LICENSE).
