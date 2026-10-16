# -------------------------------------------------------------------------------------------------
#  Copyright (C) 2015-2026 Nautech Systems Pty Ltd. All rights reserved.
#  https://nautechsystems.io
#
#  Licensed under the GNU Lesser General Public License Version 3.0 (the "License");
#  You may not use this file except in compliance with the License.
#  You may obtain a copy of the License at https://www.gnu.org/licenses/lgpl-3.0.en.html
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
# -------------------------------------------------------------------------------------------------
"""Run Make checks with checked discovery and intact filename arguments."""

import os
import shlex
import subprocess
import sys
from pathlib import Path


__all__: tuple[str, ...] = ()

ROOT = Path(__file__).resolve().parent.parent
INVENTORIES = {
    "python": ("PYTHON_FILES", ["*.py"], (b".py",)),
    "shell": ("SHELL_FILES", ["scripts", "sync", "tests"], (b".bash", b".sh")),
    "test": ("TEST_FILES", ["tests", "scripts/ci"], (b".bash",)),
    "action": ("ACTION_FILES", [".github"], (b".yaml", b".yml")),
    "markdown": ("MARKDOWN_FILES", ["*.md"], (b".md",)),
}


def main() -> int:
    """Report discovery or checker failures without continuing with partial results."""
    list_only = sys.argv[1:2] == ["--list"]
    arguments = sys.argv[2:] if list_only else sys.argv[1:]
    if (
        len(arguments) != 2  # noqa: PLR2004 - kind and Make variable origin
        or arguments[0] not in INVENTORIES
        or (arguments[0] == "markdown" and not list_only)
    ):
        sys.stderr.write(
            "Usage: run-make-check.py [--list] {python|shell|test|action|markdown} "
            "MAKE_VARIABLE_ORIGIN\n",
        )
        return 2
    try:
        if list_only:
            files = selected_files(*arguments)
            sys.stdout.buffer.write(b"".join(os.fsencode(path) + b"\0" for path in files))
        else:
            run_check(*arguments)
    except subprocess.CalledProcessError as exc:
        return exc.returncode if exc.returncode > 0 else 128 - exc.returncode
    except (OSError, ValueError) as exc:
        sys.stderr.write(f"{exc}\n")
        return 2
    return 0


def run_check(kind: str, origin: str) -> None:
    """Run the selected checks, isolating test children from commit-hook Git variables."""
    files = selected_files(kind, origin)
    environment = os.environ.copy()
    if kind == "test":
        result = subprocess.run(
            ["git", "rev-parse", "--local-env-vars"],  # noqa: S607 - Git is required
            cwd=ROOT,
            stdout=subprocess.PIPE,
            check=True,
        )
        for name in result.stdout.decode("ascii").splitlines():
            environment.pop(name, None)
    if kind == "python":
        commands = [["python3", "-m", "py_compile", *files]]
    elif kind == "action":
        commands = [["bash", "scripts/check-github-action-shas.sh", *files]]
    else:
        commands = [["bash", *(["-n"] if kind == "shell" else []), path] for path in files]
    for command in commands:
        if kind == "test":
            sys.stdout.write(f"\nRunning {command[-1]}\n")
            sys.stdout.flush()
        subprocess.run(command, cwd=ROOT, env=environment, check=True)  # noqa: S603 - argv, never shell code


def selected_files(kind: str, origin: str) -> list[str]:
    """Accept an explicit shell-word list or finish Git discovery before using its output."""
    variable, pathspecs, suffixes = INVENTORIES[kind]
    if origin != "file":
        files = shlex.split(os.environ[variable])
    else:
        result = subprocess.run(  # noqa: S603 - fixed Git argv and repository pathspecs
            [  # noqa: S607 - Git is a required development tool
                "git",
                "ls-files",
                "-z",
                "--cached",
                "--others",
                "--exclude-standard",
                "--",
                *pathspecs,
            ],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            check=True,
        )
        paths = result.stdout.split(b"\0")
        files = [
            os.fsdecode(path)
            for path in sorted(paths)
            if path.endswith(suffixes) and (kind != "test" or b"/test-" in path)
        ]
    if not files:
        raise ValueError(f"No {kind} files selected")
    # A leading dash must stay a filename when passed to an interpreter.
    return [str(ROOT / path) for path in files]


if __name__ == "__main__":
    sys.exit(main())
