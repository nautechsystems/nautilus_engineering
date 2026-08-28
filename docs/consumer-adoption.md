# Adopt Nautilus Engineering Files

Use this guide to vendor shared standards, configuration, pre-commit definitions, or repository
checks into a Nautilus repository. Vendoring copies committed files into the consumer and records
their source and hashes in `.nautilus-engineering.lock`.

## Before you start

- Use Git, Bash, and Python 3.12 or later. On Windows, run the Bash commands from Git Bash or MSYS2.
- Work from the `nautilus_engineering` repository root at the exact commit you intend to adopt.
- Confirm that the repository URL in `sync/manifest.toml` contains that commit. Other contributors
  and CI must be able to reproduce the lock without access to your local checkout.
- Run the command against the root of a Git consumer repository.
- Start with a clean consumer worktree. Vendoring replaces managed targets, and successful
  transactions remove their temporary backups.
- Review existing files and local policy before replacing a target. The sync command uses committed
  source content and ignores uncommitted source changes.

Consumers that render shared pre-commit definitions need `.pre-commit-config.yaml` with one
top-level `repos:` key. Keep repository-specific hooks, exclusions, and top-level settings outside
the managed section.

Before the first sync, add its transient state to the consumer's `.gitignore`:

```gitignore
.nautilus-engineering.syncing
.nautilus-engineering.sync-lock
.nautilus-engineering.tmp.*
```

The ignore rules prevent accidental staging of recovery data. The checker still fails while a sync
marker or process lock exists.

## Choose a selection

Profiles select related artifacts. Multiple profiles form a union, so overlapping artifacts are
copied once. Use profiles for a new repository. In a mature repository, select artifacts explicitly
and adopt them in reviewable groups.

Pair a functional profile with `sync` so the consumer receives the lock checker and the managed
pre-commit checks. The `pre-commit` profile already includes `sync`.

| Profile         | Shared files selected                                                            | Consumer contract                                                     |
| --------------- | -------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| `pre-commit`    | Hook definitions, lint configs, Markdown table check, renderer, and sync check   | Existing config with one `repos:` key                                 |
| `sync`          | Lock checker, sync hook definition, and renderer                                 | Pre-commit config or equivalent unconditional local and CI wiring     |
| `markdown`      | Written standard, markdownlint config, table check, and hooks                    | Markdown paths and repository-specific exclusions                     |
| `shell`         | shfmt and ShellCheck definitions                                                 | Bash-compatible scripts and any local exclusions                      |
| `yaml`          | yamllint config and definition                                                   | YAML paths and any generated-file exclusions                          |
| `toml`          | Taplo config and definition                                                      | One complete repository Taplo policy                                  |
| `cargo`         | Shared tool catalog, Cargo version readers, cooldown check, and update command   | Local compiler pin, tracked lockfiles, Cargo policy, and script tests |
| `python`        | Shared tool catalog, version readers, and no-build-package check                 | Local Python projects, uv lockfiles, and any unique tool pins         |
| `security`      | Shared tool catalog, typed audit runner, version readers, and scanner installers | Local audit policy, scanner configs, dependency files, and CI wiring  |
| `tool-versions` | Shared catalog and readers for Cargo, Rust, repository tools, and uv             | Local compiler pin and any unique tool pins                           |
| `ci`            | GitHub Action SHA checker                                                        | Workflow paths and network access to resolve release tags             |
| `all`           | Every artifact in the manifest                                                   | Every contract above                                                  |

Run the catalog command to see each artifact's default target and profile membership:

```bash
sync/sync.bash list
```

Use `--target ARTIFACT=PATH` for a repository that stores an artifact elsewhere. Artifacts marked
with `target_fixed = true` reject overrides because the managed files refer to their manifest paths.

## Adopt into a new repository

For a new repository that wants the common pre-commit and Markdown baseline, run:

```bash
consumer_repo=../new_nautilus_repository
sync/sync.bash vendor \
  --consumer "$consumer_repo" \
  --profile pre-commit \
  --profile markdown
```

The command writes the selected files and `.nautilus-engineering.lock`. It does not stage or commit
them.

From the consumer root, render the managed pre-commit entries:

```bash
python3 scripts/manage-nautilus-engineering-pre-commit.py render
```

The renderer removes byte-identical unmanaged copies of selected definitions. It stops if an
unmanaged definition has the same repository or hook identity but different content. Preserve the
local variant by leaving that fragment unselected, or reconcile the difference as an explicit part
of the adoption.

Review the complete consumer diff, including the lock and checker. Then verify the worktree copies
and rendered section:

```bash
bash scripts/check-nautilus-engineering-sync.bash
python3 scripts/manage-nautilus-engineering-pre-commit.py check
```

After staging every adoption path, verify the exact staged files:

```bash
bash scripts/check-nautilus-engineering-sync.bash --staged
python3 scripts/manage-nautilus-engineering-pre-commit.py check --staged
```

Run the consumer's focused integration tests for each adopted check. Run its full pre-commit gate
when the adoption changes managed hook definitions.

## Adopt into NautilusTrader

NautilusTrader already has extensive local hooks, exclusions, script tests, and established target
paths. Start with the sync machinery and the three baseline configurations below instead of
selecting a broad profile:

```bash
sync/sync.bash vendor \
  --consumer ../nautilus_trader \
  --profile sync \
  --artifact markdownlint-config \
  --artifact yamllint-config \
  --artifact taplo-config
```

Before running the command, compare those targets with the source revision. If any differ, include
the behavior change and its validation in the adoption review.

If the Markdown or YAML policy must differ, vendor its shared baseline to another path with
`--target` and extend that file from the root configuration. Keep Taplo local until the whole shared
configuration applies because Taplo does not support cross-file inheritance.

Render the sync hooks, run both checker modes from the preceding section, and keep the remaining
pre-commit definitions local. Move another definition into the managed section only after its local
variant has been reconciled. This preserves NautilusTrader's Markdown exclusions and additional
local hooks.

NautilusTrader uses a different target for the written Markdown standard. Add it to an existing
lock with:

```bash
sync/sync.bash update \
  --consumer ../nautilus_trader \
  --add markdown-standard \
  --target markdown-standard=docs/developer_guide/markdown_style.md
```

Its GitHub Action checker also has a local target:

```bash
sync/sync.bash update \
  --consumer ../nautilus_trader \
  --add github-action-pin-check \
  --target github-action-pin-check=scripts/ci/check-github-action-shas.sh
```

Vendor the Cargo profile's artifacts together, run NautilusTrader's consumer tests for the cooldown
checker and dependency update transaction, and commit them only when those tests pass:

```bash
sync/sync.bash update \
  --consumer ../nautilus_trader \
  --add cargo-tool-version \
  --add cargo-cooldown-check \
  --add rust-toolchain-version \
  --add cargo-dependency-update
```

The shared Cargo scripts discover tracked lockfiles and update each corresponding workspace. They
also validate paths and serialize update transactions. Consumer tests must cover NautilusTrader's
lockfile layout, Cargo metadata, and local command wiring.

## Update an existing adoption

The update command reads the lock and preserves its artifact set, recorded profiles, and target
paths. It uses committed content from the local source checkout's `HEAD`; it does not fetch or
choose a revision.

Fetch the source repository, check out the reviewed revision, and update the consumer:

```bash
git fetch origin
git switch --detach <reviewed-revision>
sync/sync.bash update --consumer ../nautilus_trader
```

New artifacts added to a recorded profile remain unadopted. Add them explicitly with one or more
`--add` options. Update stops if the source manifest no longer contains a locked artifact, and it
does not change an existing target override.

Review every changed artifact together with the revision and hashes in
`.nautilus-engineering.lock`. Repeat the worktree, staged, and consumer integration checks used for
the first adoption.

## Change the managed selection

Use `update --add` to grow an existing selection without restating it:

```bash
sync/sync.bash update \
  --consumer ../consumer_repository \
  --add github-action-pin-check \
  --target github-action-pin-check=scripts/ci/check-github-action-shas.sh
```

Changing a locked target or removing an artifact requires a separate migration. Run `vendor` with
the complete intended selection and every retained target override. The command reports paths that
were managed by the old lock but are absent from the new selection. It leaves those paths unchanged;
delete them only as an explicit, reviewed consumer change.

Never rerun `vendor` with only the new artifact or profile when a consumer lock already exists.
`vendor` replaces the managed selection in the lock, while `update` preserves it.

## Consumer file contracts

Shared scripts separate central release pins from consumer-owned policy:

| Artifact family     | Values read from the consumer                                        |
| ------------------- | -------------------------------------------------------------------- |
| Shared tools        | Exact versions in `.nautilus-engineering/tools.toml`                 |
| Unique tools        | Tool sections in local `tools.toml` or Cargo workspace metadata      |
| Supply-chain audits | Dependency surfaces and enforcement choices in `security-audit.toml` |
| Scanner policy      | Local deny, OSV Scanner, cargo-vet, and advisory exception files     |
| Cargo cooldown      | `Cargo.toml` cooldown metadata and optional cargo-vet audits         |
| Rust toolchain      | Exact channel in `rust-toolchain.toml`                               |
| Python builds       | `uv.lock` and matching `pyproject.toml` `no-build-package` lists     |

Keep repository policy files local. Shared version readers fail if a shared tool is also pinned in
a local catalog. Use [`supply-chain-security.md`](supply-chain-security.md) to define audit policy
and wire the same runner into local pre-flight checks and CI.

## Sync and recovery behavior

Vendoring rejects absolute paths, parent traversal, symlink traversal, Windows path aliases,
special-file targets, duplicate targets, and overlapping managed paths. It reads each artifact from
the committed source revision, stages replacements in the consumer, and replaces the lock last.

During replacement, prior files and the old lock remain under the temporary directory named in
`.nautilus-engineering.syncing`. The command restores them after an ordinary error or handled
interrupt. An abrupt interruption leaves the marker, process lock, and readable backups for manual
recovery. Inspect the marker and backup directory before removing either lock. The checker fails
while the marker or process lock remains.

The lock and checker detect accidental drift. They are not a security boundary: a consumer change
can modify a managed file, its lock, and the checker together. Review those changes as one unit. The
transaction also assumes no hostile concurrent filesystem changes and does not provide
database-style durability across power loss or filesystem failure.

Consumer repositories must retain LF line endings for vendored text. The staged checker reads Git
blobs and enforces executable modes on every platform. Worktree mode skips executable-mode checks
on Git Bash because Windows filesystems do not expose the Git executable bit reliably; its success
message reports that limitation.
