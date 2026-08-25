# Pre-commit Definitions

Each YAML file in this directory is a sequence of complete pre-commit repository entries. The
entries are sources for a managed section of a consumer's `repos` list; they are not standalone
`.pre-commit-config.yaml` files.

Pre-commit and prek do not support including repository entries from another file. Consumer
adoption therefore copies selected definitions into a clearly marked managed section. Keep
repository-specific hooks, exclusions, and top-level settings outside that section.

The sync check is an unconditional local hook. Keep `always_run: true` and `pass_filenames: false`
so lock-only changes, deletions, and renamed managed files cannot bypass it.

Each definition records its hook revision once. Do not maintain a separate version catalog that
must agree with these files.
