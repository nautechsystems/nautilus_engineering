# Pre-commit Definitions

Each YAML file in this directory contains a sequence of complete pre-commit repository entries for the managed
regions of a consumer's `repos` list. These files are not standalone `.pre-commit-config.yaml` files.

Pre-commit and prek cannot include repository entries from another file. Consumer adoption copies selected
definitions into clearly marked managed regions. Keep repository-specific hooks, exclusions, and top-level
settings outside those regions.

See the [consumer adoption guide](../docs/consumer-adoption.md) for the complete procedure, including profile
selection, rendering, staged checks, and conflict handling.

Vendor the `pre-commit` profile for all shared pre-commit definitions. For a narrower adoption,
pair the selected definition artifacts with the `sync` profile. From the consumer root, render the managed
content:

```bash
python3 scripts/manage-nautilus-engineering-pre-commit.py render
```

The renderer supports one combined section or separate sync and shared-hooks regions. Use the split
layout when sync checks must run first while consumer-owned checks precede the other shared hooks.
See [Choose a pre-commit layout](../docs/consumer-adoption.md#choose-a-pre-commit-layout) for the
marker contract.

The renderer removes byte-identical unmanaged definitions. If a local variant has the same repository or
hook identity as a selected definition, the renderer stops before writing the configuration. This prevents
rendering from overwriting repository-specific changes.

**Fixed targets**: Do not change the manifest targets for definition fragments, the sync checker, or the
managed-section command. The fragments and commands refer to those paths directly.

The sync check and managed-section check are unconditional local hooks. Keep `always_run: true` and
`pass_filenames: false` on both so lock-only changes, deletions, and renamed managed files cannot bypass them.
During pre-commit, the managed-section check compares staged content.

Each definition records its rendered hook revision or managed dependency pin. The root
`tools.toml` remains the version source of truth, and the tool-pin check rejects drift.
