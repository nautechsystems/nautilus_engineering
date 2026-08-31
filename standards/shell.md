# Shell Style

Standard revision: 1

This document defines a shared shell baseline for repositories that adopt a local copy. Keep copies
byte-for-byte identical to the maintained source and put repository-specific paths, commands, and
exceptions in a separate local guide.

Bash is the default. Use POSIX `sh` only when a supported caller cannot rely on Bash being
installed.

## Requirement levels

Each rule has one of three levels:

- **Required:** Applies to every in-scope shell artifact. Rules stated as unqualified imperatives
  such as "Use" and "Do not", or with "must", are Required.
- **Preferred:** Identifies the default when more than one valid form exists. Preferred rules use
  "Prefer" and do not affect conformance.
- **Transitional:** Applies to the named construct when it is added or substantially edited, and is
  labeled **Transitional** or described as transitional. Existing instances may remain until a
  separate migration.

Statements with "may" or "allowed" grant bounded permissions rather than obligations. Any
condition limiting that permission is Required. A repository may document a narrower local
exception where its supported environment or existing interface requires one.

## Authority and references

Treat this standard as the project policy. Use the
[GNU Bash manual](https://www.gnu.org/software/bash/manual/) to resolve Bash semantics and the
[POSIX Shell Command Language](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html)
to resolve POSIX `sh` semantics.

The [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html) is an advisory
reference. This standard takes precedence where its portability target, extensions, shebangs,
formatting, or repository conventions differ. ShellCheck and `shfmt` enforce a mechanical subset;
clean tool output does not prove runtime behavior.

## Choose shell for the task

Before adding a script, search for an existing script, task-runner command, or installed tool that
already provides the behavior. Add a script when it gives procedural logic one testable, linted
source of truth.

| Location     | Owns                                                                 | Delegates                                              |
| ------------ | -------------------------------------------------------------------- | ------------------------------------------------------ |
| CI workflow  | Events, permissions, matrices, runners, secrets, and hosted actions  | Multi-step shell behavior                              |
| Task runner  | Discoverable tasks, dependencies, variables, and concurrency limits  | Non-trivial control flow                               |
| Shell script | Validation, reusable command sequences, retries, and transformations | Workflow orchestration and build dependency management |

Prefer a script when:

- A command sequence is used by more than one workflow, task-runner command, or developer task.
- An inline CI step contains branches, loops, retries, or failure handling worth testing outside
  the workflow.
- A task-runner recipe needs enough procedural logic that quoting, error propagation, or platform
  behavior becomes hard to review.
- A repeated maintenance or release task benefits from ShellCheck, `shfmt`, and focused tests.

Prefer to keep a command inline when it is short, used once, and clearer in its caller. Do not wrap
one stable command only to add another file.

Use another language when the task centers on structured-data processing, complex state, parallel
work, performance-sensitive logic, or domain behavior that needs extensive unit tests. Script
length is a review signal rather than an automatic failure: consider the expected growth and
whether someone other than the author can maintain the control flow safely.

When extracting CI logic, keep workflow expressions, permissions, secret selection, and runner
selection in the workflow. Pass ordinary values through arguments or environment variables. The
script's exit status must remain the step's exit status.

## Choose the shell and extension

The extension identifies the shell language, not whether the file is executable or sourceable.

| Extension | Interpreter | Use                                                                      |
| --------- | ----------- | ------------------------------------------------------------------------ |
| `.bash`   | Bash        | Default for new scripts and sourceable Bash files.                       |
| `.sh`     | POSIX `sh`  | Only when a supported caller has a real requirement to run without Bash. |

Use `#!/usr/bin/env bash` for `.bash` files and `#!/usr/bin/env sh` for `.sh` files. Keep the
shebang even when a task runner or CI invokes the file through `bash` or `sh`, because tools and
direct callers use it to identify the interpreter.

Bash is preferred for normal development and CI scripts because Nautilus repositories already
depend on it and its features make non-trivial shell code clearer. These features include
`pipefail`, `[[ ... ]]`, arrays, process substitution, and function-local variables.

Use POSIX `sh` for a small bootstrap or wrapper only when avoiding a Bash dependency is part of its
supported interface. Test the script under every supported `/bin/sh`; simple syntax and a clean
ShellCheck result do not prove portable behavior across different `sh` implementations.

The extension policy is transitional because existing filenames may predate it, so some `.sh`
files contain Bash. Treat their shebangs as the source of truth. Do not rename an existing script
only to change its extension. Apply the policy to new files and to scoped renames that already
update every call site and document.

## Define the portability target

A script must support every platform on which its callers run. Unless its purpose states a narrower
target, write it for Linux, macOS, and Windows through Git Bash or MSYS2. WSL support may be added,
but it does not replace Git Bash and MSYS2 support where those remain documented callers.

Use Bash 3.2 as the default language floor because it is available on supported macOS systems.
Avoid Bash 4+ features unless every caller provisions a newer version. Common Bash 4+ features and
portable alternatives include:

| Feature                           | Bash version | Portable alternative               |
| --------------------------------- | ------------ | ---------------------------------- |
| Associative arrays (`declare -A`) | 4.0+         | Files, simple arrays, or functions |
| `readarray` / `mapfile`           | 4.0+         | `while read` loops                 |
| `${var,,}` / `${var^^}`           | 4.0+         | `tr` for case conversion           |

A CI-only script may use a newer Bash version or platform-specific tool when every caller
guarantees that environment. Document the constraint near the code that depends on it. A path under
a CI directory does not by itself make a script Linux-only because CI may also use macOS and
Windows runners.

Inline CI shell may use features guaranteed by that step's runner. Shared scripts invoked by the
step retain their own portability target unless every direct caller guarantees the same version.

### System utilities

Prefer options supported by both GNU and BSD utilities. When no common form exists, detect the
capability or operating system and implement both forms.

| Operation         | GNU form       | BSD or macOS form | Portable approach                                         |
| ----------------- | -------------- | ----------------- | --------------------------------------------------------- |
| In-place `sed`    | `sed -i`       | `sed -i ''`       | Use a backup suffix such as `sed -i.bak`, then remove it. |
| File size         | `stat -c '%s'` | `stat -f '%z'`    | Try or select the supported form.                         |
| SHA-256           | `sha256sum`    | `shasum -a 256`   | Detect the command and keep output handling equal.        |
| Canonical path    | `readlink -f`  | No common form    | Avoid it or resolve from a known directory with `pwd`.    |
| Extended matching | `grep -P`      | No common form    | Use `grep -E` when it expresses the same pattern.         |
| Nanosecond time   | `date +%N`     | No common form    | Use an existing run ID or `$RANDOM` for cache busting.    |

Quote paths and expansions so spaces do not change argument boundaries. Do not assume filesystem
paths are case-sensitive. Resolve bundled resources from the script location. Resolve a target
repository from an explicit root argument or the repository discovery mechanism defined by the
script's interface. Treat user-supplied relative paths according to that interface. Do not make
behavior depend on an accidental working directory.

Use only commands installed by the documented development or runner setup. If an optional command
is necessary, check for it with `command -v` and report how to install or replace it. Store scripts
with LF endings through `.gitattributes` or an equivalent repository mechanism.

## Place and name scripts

- Put general development and maintenance commands in the repository's script directory.
- Put workflow-specific build, test, publication, and verification commands in the established CI
  script directory.
- Put repository checks in the established hook or check directory.
- Keep component-specific scripts beside the component when a central script directory would hide
  their ownership.

Prefer lowercase kebab-case under general and CI script directories. Name a companion regression
test to match the repository's documented test inventory. Within that constraint, prefer
`test-<script-name>.bash` or `test-<script-name>.sh` so the tested pair sorts together. Prefer an
established local naming family for repository hooks and component scripts.

Prefer to keep each script focused on one task and to extend an existing script when new logic
shares the same responsibility.

## Structure scripts for reliable execution

Start standalone Bash scripts with:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

Use `set -eu` in a standalone POSIX `sh` script. POSIX added `pipefail` in POSIX.1-2024, but
supported `/bin/sh` implementations may not provide it. Check pipeline behavior explicitly when a
failure must propagate. If a script cannot use these options, explain the specific control flow
that makes an option unsafe.

### Handle failures explicitly

`set -e` does not exit for every failed command. Bash suppresses it in conditions for `if`, `while`,
and `until`, in most `&&` and `||` lists, after `!`, and in parts of pipelines. It can also be
suppressed inside a function or command substitution because of the context in which it was called.

Do not rely on implicit exit when a failed command must stop a later state change. Invoke the
command separately so strict mode applies, or inspect its status explicitly and return or exit on
failure. Keep `&&` and `||` chains short enough that every accepted failure is clear.

### Validate and preserve values

- Validate required arguments and environment variables before changing state. Print concise usage
  text and exit nonzero for invalid input.
- Quote parameter and command expansions. Use `"$@"` to forward arguments and Bash arrays for
  argument lists instead of building a command string. Do not use `eval`.
- Read text with `IFS= read -r` unless field splitting or backslash processing is the explicit
  format.
- Separate a function-local declaration from command substitution when the command's status
  matters:

```bash
local value
value=$(produce_value)
```

- Prefer lowercase names for function-local variables and uppercase names for exported environment
  variables and repository-wide constants. Prefer an established local family where changing it
  would create asymmetry.

### Control output and side effects

- Keep machine-readable output on standard output and diagnostics on standard error when callers
  capture the result. Use `printf` for arbitrary or variable data, output without a newline,
  escape-sensitive text, and machine-readable output with a defined format. `echo` is allowed only
  for fixed human-readable lines that do not begin with an option or depend on escape handling.
- Do not end routine status output with a terminating period. Keep punctuation when the output is a
  complete explanatory or diagnostic sentence.
- Create temporary files and directories with `mktemp`, register cleanup with `trap`, and constrain
  cleanup to the exact paths created by the script.
- Bound retries, report the final failure, and return a nonzero status when the requested operation
  does not complete.
- Do not print secrets or enable command tracing around credentials. Pass secrets through the
  environment or the tool's supported secret input.
- Use comments only for constraints or behavior that the commands do not make clear.

Give a standalone script executable permissions when users or tools call it as `./path`. A
sourceable file does not need executable permissions. Git's tracked executable mode remains the
source of truth on filesystems that do not expose Unix modes reliably.

Prefer executing a script in a child process. Source a file only when the caller must share its
functions or shell state. A sourceable Bash file must not call `exit` or change the caller's shell
options. Return errors from functions and let the caller choose its error policy. Use
`${BASH_SOURCE[0]}` instead of `$0` to resolve the source file's location.

For a standalone script that needs several functions, prefer to use a `main` entry point, define
`main` first, and place called functions below their callers. When a script uses `main`, invoke
`main "$@"` after all function definitions so every function exists before execution starts.

## Integrate with task runners and CI

Use task-runner commands as the stable, discoverable interface that developers run. Keep
dependencies, build variables, and concurrency limits in the task runner, then invoke a script
with an explicit interpreter.

Provide CI workflow context through named environment variables. Prefer to call the same script
used locally where practical. Keep CI-specific output files and expressions at the workflow
boundary when the script is also a local command. A script dedicated to one CI system may write
its integration files when that behavior is its stated purpose.

Multiline inline shell follows the same quoting, failure-handling, and portability rules. Extract it
when branches, loops, retries, cleanup, or reusable behavior warrant focused tests.

## Format and lint

Nautilus Engineering's tool catalog owns shared ShellCheck and `shfmt` versions. Its managed shell
hook definition owns formatter and linter options, and automated checks keep the embedded hook
revisions aligned with the catalog. Consumer locks record the exact source revision and hashes.
Do not repeat numeric tool versions or complete option lists in this standard.

The shared `shfmt` definition uses two-space indentation, indented case branches, consistent
redirect spacing, and the Bash parser. ShellCheck checks quoting, expansion, control flow,
portability, and common command errors.

Run both configured hooks against the exact changed scripts. For a repository that uses `prek`:

```bash
prek run shfmt --files path/to/script.bash
prek run shellcheck --files path/to/script.bash
```

`shfmt` updates files in place. Review its changes before running ShellCheck. ShellCheck selects the
language from the shebang, so a `.sh` file with `#!/usr/bin/env sh` receives POSIX checks even though
the formatter uses the common Bash parser.

Keep ShellCheck suppressions on the narrowest applicable line. Add a nearby reason when the
constraint is not clear from the code. Do not disable a check for a whole repository to silence one
script.

ShellCheck's optional rules include both defect checks and subjective style checks. Enable a named
optional rule only after auditing every consumer in scope and deciding how existing findings will
be handled. Do not enable all optional rules as a quality shortcut.

Reject executable files without shebangs, mixed line endings, trailing whitespace, and unresolved
merge markers through repository checks. These checks complement ShellCheck; they do not replace a
runtime test.

## Test behavior

Run the smallest test that exercises the changed branches and failure paths. Add a companion shell
test for logic that can regress independently of its workflow. This includes parsing, multi-branch
decisions, retries and cleanup, policy checks, and material external side effects. A domain-level
suite may cover cooperating scripts, and a thin wrapper does not need a one-to-one test when that
suite invokes it and proves its behavior.

Each companion test:

- Creates isolated state under `mktemp -d` and removes it on exit.
- Supplies fake external commands through a temporary `PATH` instead of changing production code.
- Uses distinct inputs and asserts the exact exit status, every stable contract-relevant output
  value, and all material side effects. Use anchored or presence checks only for output documented
  as variable or diagnostic.
- Covers success, invalid input, dependency failure, and cleanup when those paths exist.
- Fails when a required test command is unavailable on a supported platform.
- May skip a platform that is explicitly outside the behavior's supported scope. CI must run the
  test on every supported platform where the behavior applies.
- Runs from the repository's documented script-test command and CI inventory.

When a script has callers on multiple operating systems, exercise platform-sensitive changes on
each caller's relevant CI matrix. A Linux test plus clean ShellCheck output does not prove macOS or
Windows behavior.

## Review checklist

- The behavior is not already available from a script, task-runner command, installed tool, or
  simple native workflow feature.
- The workflow, task runner, and script own the right parts of the operation.
- Shell remains appropriate for the task's data, state, control flow, and expected growth.
- The extension, shebang, executable mode, and documented portability target agree.
- Bundled resources and target repository discovery do not depend on an accidental working
  directory.
- Arguments, failures, temporary files, retries, output, and secrets have explicit handling.
- Focused behavior tests, `shfmt`, and ShellCheck pass for the final changed files.
- Every call site, workflow path filter, test inventory, and document uses the final filename.
