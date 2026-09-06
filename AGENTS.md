# Repository Instructions

This repository maintains standards, profiles, and checks shared by Nautilus repositories.

## Shell

- Before auditing or changing a shell artifact, read and apply
  [Shell Style](standards/shell.md).
- Treat this repository as a consumer of the shell standard it maintains. During an audit, report
  every Required violation in scope. Report a Transitional construct as nonconforming only when it
  was added or substantially edited without following its named rule.
- Keep modernization within the requested scope. Existing Transitional instances conform and may
  remain; do not edit unrelated scripts solely to migrate them.
- Preserve documented interfaces and behavior when modernizing a script. Run the smallest relevant
  behavior test and the configured shell hooks against the exact changed scripts.
- Keep shared standards generic. Put repository-specific paths, commands, and exceptions in a
  separate local guide.
