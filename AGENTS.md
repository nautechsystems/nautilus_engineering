# Repository Instructions

This repository contains shared standards, profiles, and checks for Nautilus repositories.

## Shell

- Before you audit or change a shell artifact, read and apply [Shell Style](standards/shell.md).
- Treat this repository as a consumer of the shell standard it maintains. During an audit, report each
  Required violation in scope. Report a Transitional construct as nonconforming only when it was added or
  substantially edited and did not follow its named rule.
- Keep modernization within the requested scope. Existing Transitional instances conform and may remain. Do
  not edit unrelated scripts only to migrate them.
- When you modernize a script, preserve its documented interfaces and behavior. Run the smallest relevant
  behavior test and the configured shell hooks against the exact changed scripts.
- Keep shared standards generic. Put repository-specific paths, commands, and exceptions in a separate local
  guide.
