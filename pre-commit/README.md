# Pre-commit Definitions

Each YAML file in this directory is a sequence of complete pre-commit repository entries. The
entries are sources for a managed section of a consumer's `repos` list; they are not standalone
`.pre-commit-config.yaml` files.

Pre-commit and prek do not support including repository entries from another file. Consumer
adoption therefore copies selected definitions into a clearly marked managed section. Keep
repository-specific hooks, exclusions, and top-level settings outside that section.

After vendoring the selected definitions and the `pre-commit-manager` artifact, render the managed
section with:

```bash
python3 scripts/manage-nautilus-engineering-pre-commit.py render
```

The renderer absorbs byte-identical unmanaged definitions. It rejects selected definitions that
have a local variant with the same repository or hook identity, so repository-specific changes are
not overwritten as a side effect of adoption.

The definition fragments, sync checker, and managed-section command use fixed manifest targets.
Do not retarget them: the fragments and commands refer to those paths directly.

The sync check is an unconditional local hook. Keep `always_run: true` and `pass_filenames: false`
so lock-only changes, deletions, and renamed managed files cannot bypass it. The managed-section
check has the same settings and compares staged content during pre-commit.

Each definition records its hook revision once. Do not maintain a separate version catalog that
must agree with these files.
