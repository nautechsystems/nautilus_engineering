#  Copyright (C) 2015-2026 Nautech Systems Pty Ltd. All rights reserved.
#  https://nautechsystems.io
#
#  Licensed under the GNU Lesser General Public License, Version 3.0 (the "License");
#  You may not use this file except in compliance with the License.
#  You may obtain a copy of the License at https://www.gnu.org/licenses/lgpl-3.0.en.html
#
#  Unless required by applicable law or agreed to in writing, software distributed under the
#  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
#  express or implied. See the License for the specific language governing permissions and
#  limitations under the License.
"""Check CI and pre-commit versions against tools.toml."""

import re
import shutil
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path


__all__: tuple[str, ...] = ()

REPO_LINE = re.compile(r"^\s*-\s+repo:\s+([^\s#]+)")
REV_LINE = re.compile(r"^\s+rev:\s+([^\s#]+)")


class PinError(Exception):
    pass


@dataclass(frozen=True)
class ToolPin:
    name: str
    version: str
    ci: bool
    repository: str | None
    revision: str | None
    fragment: Path | None


# Catalog validation stays in one pass so every error retains its table context
def read_catalog(path: Path) -> list[ToolPin]:  # noqa: C901, PLR0912
    try:
        catalog = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise PinError(f"{path}: {error}") from error

    pins = []
    repositories = set()
    for name, values in catalog.items():
        if not isinstance(values, dict):
            raise PinError(f"{path}: [{name}] must be a table")

        version = values.get("version")
        ci = values.get("ci", False)
        repository = values.get("pre-commit-repository")
        template = values.get("pre-commit-revision")
        fragment_value = values.get("pre-commit-fragment")
        if not isinstance(version, str) or not version:
            raise PinError(f"{path}: [{name}].version must be a non-empty string")
        if not isinstance(ci, bool):
            raise PinError(f"{path}: [{name}].ci must be a Boolean")
        if (repository is None) != (template is None):
            raise PinError(
                f"{path}: [{name}] must set both pre-commit-repository and pre-commit-revision",
            )
        if repository is not None and not isinstance(repository, str):
            raise PinError(f"{path}: [{name}].pre-commit-repository must be a string")
        if template is not None and not isinstance(template, str):
            raise PinError(f"{path}: [{name}].pre-commit-revision must be a string")
        if fragment_value is not None and not isinstance(fragment_value, str):
            raise PinError(f"{path}: [{name}].pre-commit-fragment must be a string")
        if fragment_value is not None and repository is None:
            raise PinError(f"{path}: [{name}] sets a fragment without pre-commit metadata")

        revision = None
        if template is not None:
            if template.count("{version}") != 1:
                raise PinError(
                    f"{path}: [{name}].pre-commit-revision must contain one {{version}}",
                )
            revision = template.replace("{version}", version)
            if repository in repositories:
                raise PinError(f"{path}: duplicate pre-commit repository {repository}")
            repositories.add(repository)

        pins.append(
            ToolPin(
                name=name,
                version=version,
                ci=ci,
                repository=repository,
                revision=revision,
                fragment=Path(fragment_value) if fragment_value is not None else None,
            ),
        )

    return pins


def check_versions(root: Path, pins: list[ToolPin]) -> None:
    script = root / "scripts/tool-version.sh"
    bash = resolve_bash()
    for pin in pins:
        result = subprocess.run(  # noqa: S603
            [bash, str(script), pin.name],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip()
            raise PinError(f"tools.toml [{pin.name}]: {detail}")
        if result.stdout != pin.version:
            raise PinError(f"tools.toml [{pin.name}]: tool-version.sh returned {result.stdout!r}")


def resolve_bash() -> str:
    if sys.platform != "win32":
        bash = shutil.which("bash")
        if bash is None:
            raise PinError("Bash was not found on PATH")
        return str(Path(bash).resolve())

    git = shutil.which("git")
    if git is not None:
        for root in Path(git).resolve().parents:
            bash = root / "bin" / "bash.exe"
            if bash.is_file():
                return str(bash.resolve())

    raise PinError("Git Bash or MSYS2 Bash was not found beside Git")


def read_pre_commit(path: Path) -> dict[str, tuple[str, int]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise PinError(f"{path}: {error}") from error

    entries = {}
    pending = None
    for line_number, line in enumerate(lines, start=1):
        repo_match = REPO_LINE.match(line)
        if repo_match:
            if pending is not None:
                repository, repo_line = pending
                raise PinError(f"{path}:{repo_line}: {repository} has no revision")
            repository = repo_match.group(1).strip("'\"")
            pending = None if repository == "local" else (repository, line_number)
            continue

        rev_match = REV_LINE.match(line)
        if rev_match and pending is not None:
            repository, _ = pending
            if repository in entries:
                raise PinError(f"{path}:{line_number}: duplicate repository {repository}")
            entries[repository] = (rev_match.group(1).strip("'\""), line_number)
            pending = None

    if pending is not None:
        repository, repo_line = pending
        raise PinError(f"{path}:{repo_line}: {repository} has no revision")
    return entries


# Config and fragment validation share one traversal so duplicate checks stay consistent
def check_pre_commit(root: Path, pins: list[ToolPin]) -> None:  # noqa: C901
    expected = {pin.repository: pin for pin in pins if pin.repository is not None}
    config_path = root / ".pre-commit-config.yaml"
    config_entries = read_pre_commit(config_path)

    for repository, (revision, line_number) in config_entries.items():
        pin = expected.get(repository)
        if pin is None:
            raise PinError(f"{config_path}:{line_number}: unregistered repository {repository}")
        if revision != pin.revision:
            raise PinError(
                f"{config_path}:{line_number}: {repository} uses {revision}, "
                f"expected {pin.revision} from tools.toml [{pin.name}]",
            )

    missing = [pin.repository for pin in expected.values() if pin.repository not in config_entries]
    if missing:
        raise PinError(f"{config_path}: missing registered repositories: {', '.join(missing)}")

    fragment_entries = {}
    for fragment_path in sorted((root / "pre-commit").glob("*.yaml")):
        entries = read_pre_commit(fragment_path)
        fragment_entries[fragment_path.relative_to(root)] = entries
        for repository, (revision, line_number) in entries.items():
            pin = expected.get(repository)
            if pin is None:
                raise PinError(
                    f"{fragment_path}:{line_number}: unregistered repository {repository}"
                )
            if revision != pin.revision:
                raise PinError(
                    f"{fragment_path}:{line_number}: {repository} uses {revision}, "
                    f"expected {pin.revision} from tools.toml [{pin.name}]",
                )

    for pin in pins:
        if pin.fragment is None:
            continue
        entries = fragment_entries.get(pin.fragment)
        if entries is None:
            raise PinError(f"tools.toml [{pin.name}]: missing fragment {pin.fragment}")
        if pin.repository not in entries:
            raise PinError(f"{pin.fragment}: missing tools.toml [{pin.name}] repository")


def check_ci(root: Path, pins: list[ToolPin]) -> None:
    ci_path = root / ".github/workflows/ci.yaml"
    try:
        ci = ci_path.read_text(encoding="utf-8")
    except OSError as error:
        raise PinError(f"{ci_path}: {error}") from error

    for pin in pins:
        if not pin.ci:
            continue
        lookup = f"scripts/tool-version.sh {pin.name}"
        if lookup not in ci:
            raise PinError(f"{ci_path}: missing tools.toml lookup for [{pin.name}]")
        if pin.version in ci:
            raise PinError(f"{ci_path}: hard-codes version {pin.version} for [{pin.name}]")


def _write(message: str, *, error: bool = False) -> None:
    stream = sys.stderr if error else sys.stdout
    stream.write(f"{message}\n")


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    try:
        pins = read_catalog(root / "tools.toml")
        check_versions(root, pins)
        check_pre_commit(root, pins)
        check_ci(root, pins)
    except PinError as error:
        _write(f"Tool pin check failed: {error}", error=True)
        return 1

    _write("Tool pins match tools.toml")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
