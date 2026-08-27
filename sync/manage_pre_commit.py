#!/usr/bin/env python3
"""Render or check vendored pre-commit definitions in a consumer config."""

from __future__ import annotations

import argparse
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

BEGIN_MARKER = "  # nautilus-engineering: begin"
END_MARKER = "  # nautilus-engineering: end"
DEFAULT_CONFIG = ".pre-commit-config.yaml"
DEFAULT_LOCK = ".nautilus-engineering.lock"
FRAGMENT_DIRECTORY = ".nautilus-engineering/pre-commit"


class ManagedSectionError(Exception):
    pass


@dataclass(frozen=True)
class Fragment:
    artifact: str
    path: str
    content: str


def run_git(root: Path, *args: str) -> bytes:
    process = subprocess.run(
        ["git", "-C", str(root), *args],
        capture_output=True,
        check=False,
    )
    if process.returncode != 0:
        detail = process.stderr.decode("utf-8", errors="replace").strip()
        raise ManagedSectionError(detail or f"git {' '.join(args)} failed")
    return process.stdout


def repository_root() -> Path:
    root = run_git(Path.cwd(), "rev-parse", "--show-toplevel")
    return Path(root.decode("utf-8").strip()).resolve()


def validate_path(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ManagedSectionError(f"{label} must be a non-empty string")
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or str(path) != value
        or any(part in ("", ".", "..") for part in path.parts)
    ):
        raise ManagedSectionError(f"{label} must be a normalized repository-relative path: {value}")
    if any(part.casefold() == ".git" for part in path.parts):
        raise ManagedSectionError(f"{label} contains a reserved path component: {value}")
    return value


def reject_symlink_path(root: Path, relative: str) -> None:
    current = root
    for part in PurePosixPath(relative).parts:
        current /= part
        if current.is_symlink():
            raise ManagedSectionError(f"path traverses a symlink: {relative}")


def read_file(root: Path, relative: str, staged: bool) -> bytes:
    validate_path(relative, "path")
    if staged:
        return run_git(root, "show", f":{relative}")
    reject_symlink_path(root, relative)
    path = root.joinpath(*PurePosixPath(relative).parts)
    if not path.is_file():
        raise ManagedSectionError(f"file not found: {relative}")
    return path.read_bytes()


def decode_file(content: bytes, relative: str) -> str:
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ManagedSectionError(f"file is not UTF-8: {relative}") from exc
    if "\r" in text:
        raise ManagedSectionError(f"file must use LF line endings: {relative}")
    if not text.endswith("\n"):
        raise ManagedSectionError(f"file must end with a newline: {relative}")
    return text


def load_fragments(root: Path, lock_path: str, staged: bool) -> list[Fragment]:
    raw_lock = read_file(root, lock_path, staged)
    try:
        lock = tomllib.loads(raw_lock.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
        raise ManagedSectionError(f"invalid sync lock: {exc}") from exc

    files = lock.get("file")
    if not isinstance(files, list):
        raise ManagedSectionError("sync lock has no file entries")

    fragments: list[Fragment] = []
    artifacts: set[str] = set()
    for entry in files:
        if not isinstance(entry, dict):
            raise ManagedSectionError("sync lock contains an invalid file entry")
        artifact = entry.get("artifact")
        path = validate_path(entry.get("path"), "locked path")
        if not isinstance(artifact, str):
            raise ManagedSectionError("sync lock contains an invalid artifact id")
        if artifact in artifacts:
            raise ManagedSectionError(f"sync lock repeats artifact: {artifact}")
        artifacts.add(artifact)
        parent = str(PurePosixPath(path).parent)
        if not artifact.startswith("pre-commit-") or parent != FRAGMENT_DIRECTORY:
            continue
        content = decode_file(read_file(root, path, staged), path)
        fragments.append(Fragment(artifact, path, content))

    if not fragments:
        raise ManagedSectionError("sync lock selects no pre-commit definition fragments")
    return sorted(fragments, key=lambda fragment: fragment.artifact)


def indent_fragment(fragment: Fragment) -> list[str]:
    lines = fragment.content[:-1].split("\n")
    if not lines or not lines[0].startswith("- repo:"):
        raise ManagedSectionError(f"pre-commit fragment has an invalid first line: {fragment.path}")
    return [f"  {line}" if line else "" for line in lines]


def render_section(fragments: list[Fragment]) -> list[str]:
    lines = [BEGIN_MARKER]
    for index, fragment in enumerate(fragments):
        if index:
            lines.append("")
        lines.extend(indent_fragment(fragment))
    lines.append(END_MARKER)
    return lines


def section_bounds(lines: list[str]) -> tuple[int, int] | None:
    begins = [index for index, line in enumerate(lines) if line == BEGIN_MARKER]
    ends = [index for index, line in enumerate(lines) if line == END_MARKER]
    if not begins and not ends:
        return None
    if len(begins) != 1 or len(ends) != 1 or begins[0] >= ends[0]:
        raise ManagedSectionError("pre-commit config has invalid managed-section markers")
    return begins[0], ends[0]


def find_lines(lines: list[str], target: list[str]) -> int | None:
    limit = len(lines) - len(target) + 1
    for index in range(max(limit, 0)):
        if lines[index : index + len(target)] == target:
            return index
    return None


def remove_unmanaged_fragments(lines: list[str], fragments: list[Fragment]) -> list[str]:
    updated = list(lines)
    for fragment in fragments:
        target = indent_fragment(fragment)
        while (index := find_lines(updated, target)) is not None:
            del updated[index : index + len(target)]
            if 0 < index < len(updated) and not updated[index - 1] and not updated[index]:
                del updated[index]
    return updated


def fragment_identities(fragment: Fragment) -> list[str]:
    lines = [line.strip() for line in fragment.content.splitlines()]
    identities: list[str] = []
    local = False
    repositories = 0
    for line in lines:
        if line.startswith("- repo:"):
            repositories += 1
            local = line == "- repo: local"
            if not local:
                identities.append(line)
        elif local and line.startswith("- id:"):
            identities.append(line)
    if repositories == 0:
        raise ManagedSectionError(f"pre-commit fragment has no repository entry: {fragment.path}")
    if not identities:
        raise ManagedSectionError(
            f"pre-commit fragment has no repository or hook identity: {fragment.path}"
        )
    return identities


def unmanaged_conflicts(lines: list[str], fragments: list[Fragment]) -> list[str]:
    stripped = {line.strip() for line in lines}
    return [
        fragment.artifact
        for fragment in fragments
        if any(identity in stripped for identity in fragment_identities(fragment))
    ]


def config_lines(content: str) -> list[str]:
    if "\r" in content:
        raise ManagedSectionError("pre-commit config must use LF line endings")
    if not content.endswith("\n"):
        raise ManagedSectionError("pre-commit config must end with a newline")
    return content[:-1].split("\n")


def render_config(content: str, fragments: list[Fragment]) -> str:
    lines = config_lines(content)
    bounds = section_bounds(lines)
    if bounds is not None:
        start, end = bounds
        del lines[start : end + 1]

    lines = remove_unmanaged_fragments(lines, fragments)
    conflicts = unmanaged_conflicts(lines, fragments)
    if conflicts:
        raise ManagedSectionError(
            f"pre-commit definitions conflict with the managed section: {', '.join(conflicts)}"
        )
    repos = [index for index, line in enumerate(lines) if line == "repos:"]
    if len(repos) != 1:
        raise ManagedSectionError("pre-commit config must contain one top-level repos key")
    insertion = repos[0] + 1
    section = render_section(fragments)
    if insertion < len(lines) and lines[insertion]:
        section.append("")
    lines[insertion:insertion] = section
    return "\n".join(lines) + "\n"


def check_config(content: str, fragments: list[Fragment]) -> None:
    lines = config_lines(content)
    bounds = section_bounds(lines)
    expected = render_section(fragments)
    if bounds is None or lines[bounds[0] : bounds[1] + 1] != expected:
        raise ManagedSectionError(
            "managed pre-commit section differs; run "
            "python3 scripts/manage-nautilus-engineering-pre-commit.py render"
        )

    outside = lines[: bounds[0]] + lines[bounds[1] + 1 :]
    conflicts = unmanaged_conflicts(outside, fragments)
    if conflicts:
        raise ManagedSectionError(
            "managed pre-commit definitions also appear outside the section: "
            f"{', '.join(conflicts)}"
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    render = subparsers.add_parser("render", help="render the managed section in the worktree")
    check = subparsers.add_parser("check", help="check the managed section")
    for command in (render, check):
        command.add_argument("--config", default=DEFAULT_CONFIG, help="consumer pre-commit config")
        command.add_argument("--lock", default=DEFAULT_LOCK, help="consumer sync lock")
    check.add_argument("--staged", action="store_true", help="check staged Git blobs")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        root = repository_root()
        fragments = load_fragments(root, args.lock, getattr(args, "staged", False))
        config_path = validate_path(args.config, "config path")
        config = decode_file(
            read_file(root, config_path, getattr(args, "staged", False)),
            config_path,
        )
        if args.command == "render":
            rendered = render_config(config, fragments)
            path = root.joinpath(*PurePosixPath(config_path).parts)
            if rendered != config:
                path.write_text(rendered, encoding="utf-8", newline="\n")
                print(f"Updated managed pre-commit section in {config_path}")
            else:
                print(f"Managed pre-commit section is current in {config_path}")
        else:
            check_config(config, fragments)
            state = "staged " if args.staged else ""
            print(f"Managed pre-commit section matches {state}vendored definitions")
    except (OSError, ManagedSectionError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
