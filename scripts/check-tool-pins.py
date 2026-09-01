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
"""Check CI and pre-commit versions against tools.toml."""

import re
import shutil
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path


__all__: tuple[str, ...] = ()

REPO_LINE = re.compile(r"^(\s*)-\s+repo:\s+([^\s#]+)")
REV_LINE = re.compile(r"^\s+rev:\s+([^\s#]+)")
HOOK_LINE = re.compile(r"^(\s*)-\s+id:\s+([^\s#]+)")
DEPENDENCIES_LINE = re.compile(r"^(\s*)additional_dependencies:\s*(?:&([^\s#]+))?\s*$")
DEPENDENCIES_ALIAS_LINE = re.compile(r"^\s*additional_dependencies:\s*\*([^\s#]+)\s*$")
DEPENDENCY_LINE = re.compile(r"^\s*-\s+([^\s#]+)")
STABLE_VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
RELEASE_SOURCE = re.compile(
    r"(?:crates|npm|pypi):[A-Za-z0-9][A-Za-z0-9._-]*"
    r"|(?:github|github-tags):[A-Za-z0-9._-]+/[A-Za-z0-9._-]+",
)
SECURITY_TOOLS = frozenset(
    {"cargo-audit", "cargo-deny", "cargo-vet", "osv-scanner", "pip-audit", "uv"},
)
TOOL_FIELDS = frozenset(
    {
        "ci",
        "pre-commit-dependency",
        "pre-commit-fragment",
        "pre-commit-hooks",
        "pre-commit-repository",
        "pre-commit-revision",
        "releases",
        "version",
    },
)


class PinError(Exception):
    pass


@dataclass(frozen=True)
class ToolPin:
    name: str
    version: str
    ci: bool
    releases: str
    dependency_template: str | None
    dependency: str | None
    hooks: tuple[str, ...]
    repository: str | None
    revision: str | None
    fragment: Path | None


# Catalog validation stays in one pass so every error retains its table context
def read_catalog(path: Path) -> list[ToolPin]:  # noqa: C901, PLR0912, PLR0915
    try:
        catalog = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise PinError(f"{path}: {error}") from error

    pins = []
    dependencies = set()
    hooks = set()
    repositories = set()
    for name, values in catalog.items():
        if not isinstance(values, dict):
            raise PinError(f"{path}: [{name}] must be a table")

        unknown = sorted(values.keys() - TOOL_FIELDS)
        if unknown:
            raise PinError(f"{path}: [{name}] has unknown field(s): {', '.join(unknown)}")

        version = values.get("version")
        ci = values.get("ci", False)
        releases = values.get("releases")
        dependency_template = values.get("pre-commit-dependency")
        hook_values = values.get("pre-commit-hooks")
        repository = values.get("pre-commit-repository")
        template = values.get("pre-commit-revision")
        fragment_value = values.get("pre-commit-fragment")
        if not isinstance(version, str) or not version:
            raise PinError(f"{path}: [{name}].version must be a non-empty string")
        if name in SECURITY_TOOLS and STABLE_VERSION.fullmatch(version) is None:
            raise PinError(f"{path}: [{name}].version must be a stable X.Y.Z release")
        if not isinstance(ci, bool):
            raise PinError(f"{path}: [{name}].ci must be a Boolean")
        if not isinstance(releases, str) or RELEASE_SOURCE.fullmatch(releases) is None:
            raise PinError(
                f"{path}: [{name}].releases must be crates:NAME, github:OWNER/REPO, "
                "github-tags:OWNER/REPO, npm:NAME, or pypi:NAME",
            )
        if dependency_template is not None and not isinstance(dependency_template, str):
            raise PinError(f"{path}: [{name}].pre-commit-dependency must be a string")
        if hook_values is not None and (
            not isinstance(hook_values, list)
            or not hook_values
            or any(not isinstance(hook, str) or not hook for hook in hook_values)
        ):
            raise PinError(
                f"{path}: [{name}].pre-commit-hooks must be a non-empty string array",
            )
        if (dependency_template is None) != (hook_values is None):
            raise PinError(
                f"{path}: [{name}] must set both pre-commit-dependency and pre-commit-hooks",
            )
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
        if dependency_template is not None and repository is not None:
            raise PinError(
                f"{path}: [{name}] cannot combine local and repository pre-commit metadata",
            )
        if fragment_value is not None and dependency_template is None and repository is None:
            raise PinError(f"{path}: [{name}] sets a fragment without pre-commit metadata")

        dependency = None
        if dependency_template is not None:
            if dependency_template.count("{version}") != 1:
                raise PinError(
                    f"{path}: [{name}].pre-commit-dependency must contain one {{version}}",
                )
            dependency = dependency_template.replace("{version}", version)
            if dependency in dependencies:
                raise PinError(f"{path}: duplicate pre-commit dependency {dependency}")
            dependencies.add(dependency)

        hook_names = tuple(hook_values or ())
        for hook in hook_names:
            if hook in hooks:
                raise PinError(f"{path}: duplicate pre-commit hook {hook}")
            hooks.add(hook)

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
                releases=releases,
                dependency_template=dependency_template,
                dependency=dependency,
                hooks=hook_names,
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


# Repository revisions, local hooks, and YAML dependency aliases share one traversal
def read_pre_commit(  # noqa: C901, PLR0912, PLR0915
    path: Path,
) -> tuple[dict[str, tuple[str, int]], dict[str, set[str]]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise PinError(f"{path}: {error}") from error

    entries = {}
    hooks: dict[str, set[str]] = {}
    anchors: dict[str, set[str]] = {}
    pending = None
    local_indent = None
    hook_name = None
    hook_indent = None
    dependencies_indent = None
    dependencies_hook = None
    dependencies_anchor = None
    for line_number, line in enumerate(lines, start=1):
        if dependencies_indent is not None:
            stripped = line.lstrip()
            indent = len(line) - len(stripped)
            if stripped and not stripped.startswith("#") and indent <= dependencies_indent:
                dependencies_indent = None
                dependencies_hook = None
                dependencies_anchor = None
            elif dependency_match := DEPENDENCY_LINE.match(line):
                dependency = dependency_match.group(1).strip("'\"")
                hooks[dependencies_hook].add(dependency)
                if dependencies_anchor is not None:
                    anchors[dependencies_anchor].add(dependency)
                continue

        repo_match = REPO_LINE.match(line)
        if repo_match:
            if pending is not None:
                repository, repo_line = pending
                raise PinError(f"{path}:{repo_line}: {repository} has no revision")
            repository = repo_match.group(2).strip("'\"")
            pending = None if repository == "local" else (repository, line_number)
            local_indent = len(repo_match.group(1)) if repository == "local" else None
            hook_name = None
            hook_indent = None
            continue

        rev_match = REV_LINE.match(line)
        if rev_match and pending is not None:
            repository, _ = pending
            if repository in entries:
                raise PinError(f"{path}:{line_number}: duplicate repository {repository}")
            entries[repository] = (rev_match.group(1).strip("'\""), line_number)
            pending = None
            continue

        if local_indent is None:
            continue

        hook_match = HOOK_LINE.match(line)
        if hook_match and len(hook_match.group(1)) > local_indent:
            hook_name = hook_match.group(2).strip("'\"")
            hook_indent = len(hook_match.group(1))
            if hook_name in hooks:
                raise PinError(f"{path}:{line_number}: duplicate local hook {hook_name}")
            hooks[hook_name] = set()
            continue

        if hook_name is None or hook_indent is None:
            continue

        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if stripped and not stripped.startswith("#") and indent <= hook_indent:
            hook_name = None
            hook_indent = None
            continue

        alias_match = DEPENDENCIES_ALIAS_LINE.match(line)
        if alias_match:
            alias = alias_match.group(1)
            if alias not in anchors:
                raise PinError(f"{path}:{line_number}: unknown dependency alias {alias}")
            hooks[hook_name].update(anchors[alias])
            continue

        dependencies_match = DEPENDENCIES_LINE.match(line)
        if dependencies_match:
            dependencies_indent = len(dependencies_match.group(1))
            dependencies_hook = hook_name
            dependencies_anchor = dependencies_match.group(2)
            if dependencies_anchor is not None:
                if dependencies_anchor in anchors:
                    raise PinError(
                        f"{path}:{line_number}: duplicate dependency anchor {dependencies_anchor}",
                    )
                anchors[dependencies_anchor] = set()

    if pending is not None:
        repository, repo_line = pending
        raise PinError(f"{path}:{repo_line}: {repository} has no revision")
    return entries, hooks


def check_hook_dependency(path: Path, pin: ToolPin, hook: str, dependencies: set[str]) -> None:
    expected = pin.dependency
    template = pin.dependency_template
    if expected is None or template is None:
        raise PinError(f"tools.toml [{pin.name}]: missing local dependency metadata")
    if expected not in dependencies:
        raise PinError(f"{path}: hook {hook} is missing {expected} from tools.toml [{pin.name}]")

    prefix, suffix = template.split("{version}")
    conflicting = sorted(
        dependency
        for dependency in dependencies
        if dependency != expected and dependency.startswith(prefix) and dependency.endswith(suffix)
    )
    if conflicting:
        raise PinError(
            f"{path}: hook {hook} has conflicting dependencies: {', '.join(conflicting)}",
        )


# Config and fragment validation share one traversal so duplicate checks stay consistent
def check_pre_commit(root: Path, pins: list[ToolPin]) -> None:  # noqa: C901, PLR0912
    expected_repositories = {pin.repository: pin for pin in pins if pin.repository is not None}
    config_path = root / ".pre-commit-config.yaml"
    config_entries, config_hooks = read_pre_commit(config_path)

    for repository, (revision, line_number) in config_entries.items():
        pin = expected_repositories.get(repository)
        if pin is None:
            raise PinError(f"{config_path}:{line_number}: unregistered repository {repository}")
        if revision != pin.revision:
            raise PinError(
                f"{config_path}:{line_number}: {repository} uses {revision}, "
                f"expected {pin.revision} from tools.toml [{pin.name}]",
            )

    missing = [
        pin.repository
        for pin in expected_repositories.values()
        if pin.repository not in config_entries
    ]
    if missing:
        raise PinError(f"{config_path}: missing registered repositories: {', '.join(missing)}")

    for pin in pins:
        for hook in pin.hooks:
            dependencies = config_hooks.get(hook)
            if dependencies is None:
                raise PinError(f"{config_path}: missing tools.toml [{pin.name}] hook {hook}")
            check_hook_dependency(config_path, pin, hook, dependencies)

    fragment_entries = {}
    for fragment_path in sorted((root / "pre-commit").glob("*.yaml")):
        entries, hooks = read_pre_commit(fragment_path)
        fragment_entries[fragment_path.relative_to(root)] = (entries, hooks)
        for repository, (revision, line_number) in entries.items():
            pin = expected_repositories.get(repository)
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
        fragment = fragment_entries.get(pin.fragment)
        if fragment is None:
            raise PinError(f"tools.toml [{pin.name}]: missing fragment {pin.fragment}")
        entries, hooks = fragment
        if pin.repository is not None and pin.repository not in entries:
            raise PinError(f"{pin.fragment}: missing tools.toml [{pin.name}] repository")
        if pin.dependency is not None:
            fragment_hooks = [hook for hook in pin.hooks if hook in hooks]
            if not fragment_hooks:
                raise PinError(f"{pin.fragment}: missing tools.toml [{pin.name}] hooks")
            for hook in fragment_hooks:
                check_hook_dependency(pin.fragment, pin, hook, hooks[hook])


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
