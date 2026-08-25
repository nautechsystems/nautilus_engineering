#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any

MANIFEST_PATH = "sync/manifest.toml"
PROCESS_LOCK_FILE = ".nautilus-engineering.sync-lock"
TEMP_PREFIX = ".nautilus-engineering.tmp."
PATH_CHARACTERS = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/@+ -")
WINDOWS_DEVICE_NAMES = frozenset(
    {"aux", "con", "nul", "prn"}
    | {f"com{number}" for number in range(1, 10)}
    | {f"lpt{number}" for number in range(1, 10)}
)


class SyncError(Exception):
    pass


@dataclass(frozen=True)
class Artifact:
    id: str
    source: str
    target: str
    executable: bool
    profiles: tuple[str, ...]


@dataclass(frozen=True)
class Manifest:
    repository: str
    lock_file: str
    marker_file: str
    artifacts: tuple[Artifact, ...]


@dataclass(frozen=True)
class SelectedFile:
    artifact: Artifact
    target: str
    content: bytes
    sha256: str


@dataclass(frozen=True)
class Replacement:
    destination: Path
    staged: Path
    backup: Path


def run_git(repo: Path, *args: str, text: bool = True) -> str | bytes:
    process = subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        check=False,
        text=text,
    )
    if process.returncode != 0:
        detail = process.stderr.strip() if text else process.stderr.decode().strip()
        raise SyncError(detail or f"git {' '.join(args)} failed in {repo}")
    return process.stdout


def validate_path(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise SyncError(f"{label} must be a non-empty string")
    if any(character not in PATH_CHARACTERS for character in value):
        raise SyncError(f"{label} contains an unsupported character: {value!r}")
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or str(path) != value
        or any(part in ("", ".", "..") for part in path.parts)
    ):
        raise SyncError(f"{label} must be a normalized repository-relative path: {value}")
    for part in path.parts:
        part_folded = part.casefold()
        if (
            part_folded == ".git"
            or part.startswith("-")
            or part.endswith((".", " "))
            or part_folded.partition(".")[0] in WINDOWS_DEVICE_NAMES
        ):
            raise SyncError(f"{label} contains a reserved path component: {value}")
    return value


def path_key(value: str) -> tuple[str, ...]:
    return tuple(part.casefold() for part in PurePosixPath(value).parts)


def paths_overlap(left: str, right: str) -> bool:
    left_parts = path_key(left)
    right_parts = path_key(right)
    shared = min(len(left_parts), len(right_parts))
    return left_parts[:shared] == right_parts[:shared]


def load_manifest(source: Path, revision: str) -> tuple[Manifest, bytes]:
    raw = run_git(source, "show", f"{revision}:{MANIFEST_PATH}", text=False)
    assert isinstance(raw, bytes)
    try:
        data = tomllib.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
        raise SyncError(f"invalid committed {MANIFEST_PATH}: {exc}") from exc

    if set(data) != {"version", "repository", "lock_file", "marker_file", "artifact"}:
        raise SyncError("manifest has invalid top-level fields")
    if data.get("version") != 1:
        raise SyncError("manifest version must be 1")
    repository = data.get("repository")
    if (
        not isinstance(repository, str)
        or re.fullmatch(r"https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", repository) is None
    ):
        raise SyncError("manifest repository must be an HTTPS GitHub URL")
    lock_file = validate_path(data.get("lock_file"), "lock_file")
    marker_file = validate_path(data.get("marker_file"), "marker_file")
    if paths_overlap(lock_file, marker_file):
        raise SyncError("lock_file and marker_file paths overlap")
    for managed_path, label in ((lock_file, "lock_file"), (marker_file, "marker_file")):
        if paths_overlap(managed_path, PROCESS_LOCK_FILE) or PurePosixPath(managed_path).parts[
            0
        ].casefold().startswith(TEMP_PREFIX):
            raise SyncError(f"{label} overlaps a reserved transaction path")

    raw_artifacts = data.get("artifact")
    if not isinstance(raw_artifacts, list) or not raw_artifacts:
        raise SyncError("manifest must define at least one artifact")

    artifacts: list[Artifact] = []
    ids: set[str] = set()
    targets: set[str] = set()
    for index, entry in enumerate(raw_artifacts):
        if not isinstance(entry, dict):
            raise SyncError(f"artifact {index} must be a table")
        if set(entry) != {"id", "source", "target", "executable", "profiles"}:
            raise SyncError(f"artifact {index} has invalid fields")
        artifact_id = entry.get("id")
        if not isinstance(artifact_id, str) or re.fullmatch(r"[A-Za-z0-9-]+", artifact_id) is None:
            raise SyncError(f"artifact {index} has an invalid id")
        if artifact_id in ids:
            raise SyncError(f"duplicate artifact id: {artifact_id}")
        ids.add(artifact_id)
        source_path = validate_path(entry.get("source"), f"{artifact_id}.source")
        target = validate_path(entry.get("target"), f"{artifact_id}.target")
        if target in targets:
            raise SyncError(f"duplicate default target: {target}")
        targets.add(target)
        executable = entry.get("executable")
        if not isinstance(executable, bool):
            raise SyncError(f"{artifact_id}.executable must be true or false")
        profiles = entry.get("profiles")
        if (
            not isinstance(profiles, list)
            or not profiles
            or not all(
                isinstance(profile, str) and re.fullmatch(r"[A-Za-z0-9-]+", profile) is not None
                for profile in profiles
            )
        ):
            raise SyncError(f"{artifact_id}.profiles must be a non-empty array of profile ids")
        if len(set(profiles)) != len(profiles):
            raise SyncError(f"{artifact_id}.profiles contains a duplicate")
        artifacts.append(Artifact(artifact_id, source_path, target, executable, tuple(profiles)))

    return Manifest(repository, lock_file, marker_file, tuple(artifacts)), raw


def source_revision(source: Path) -> str:
    try:
        revision = run_git(source, "rev-parse", "--verify", "HEAD^{commit}")
    except SyncError as exc:
        raise SyncError("the source repository has no committed HEAD") from exc
    assert isinstance(revision, str)
    revision = revision.strip()
    if len(revision) not in (40, 64) or any(
        character not in "0123456789abcdef" for character in revision
    ):
        raise SyncError(f"unexpected source revision: {revision}")
    return revision


def parse_target_overrides(values: list[str]) -> dict[str, str]:
    overrides: dict[str, str] = {}
    for value in values:
        artifact_id, separator, target = value.partition("=")
        if not separator or not artifact_id or not target:
            raise SyncError(f"target override must be ARTIFACT=PATH: {value}")
        if artifact_id in overrides:
            raise SyncError(f"duplicate target override: {artifact_id}")
        overrides[artifact_id] = validate_path(target, f"target for {artifact_id}")
    return overrides


def select_artifacts(
    manifest: Manifest,
    profiles: list[str],
    artifact_ids: list[str],
    overrides: dict[str, str],
) -> list[tuple[Artifact, str]]:
    by_id = {artifact.id: artifact for artifact in manifest.artifacts}
    available_profiles = {
        profile for artifact in manifest.artifacts for profile in artifact.profiles
    }
    unknown_profiles = sorted(set(profiles) - available_profiles - {"all"})
    if unknown_profiles:
        raise SyncError(f"unknown profile(s): {', '.join(unknown_profiles)}")
    unknown_ids = sorted(set(artifact_ids) - by_id.keys())
    if unknown_ids:
        raise SyncError(f"unknown artifact(s): {', '.join(unknown_ids)}")
    unknown_overrides = sorted(set(overrides) - by_id.keys())
    if unknown_overrides:
        raise SyncError(
            f"target override names unknown artifact(s): {', '.join(unknown_overrides)}"
        )

    selected_ids = set(artifact_ids)
    if "all" in profiles:
        selected_ids.update(by_id)
    else:
        for artifact in manifest.artifacts:
            if set(profiles).intersection(artifact.profiles):
                selected_ids.add(artifact.id)
    if not selected_ids:
        raise SyncError("select at least one --profile or --artifact")
    unused_overrides = sorted(set(overrides) - selected_ids)
    if unused_overrides:
        raise SyncError(
            f"target override applies to an unselected artifact: {', '.join(unused_overrides)}"
        )

    selected: list[tuple[Artifact, str]] = []
    targets: list[tuple[str, str]] = []
    reserved = (manifest.lock_file, manifest.marker_file, PROCESS_LOCK_FILE)
    for artifact in manifest.artifacts:
        if artifact.id not in selected_ids:
            continue
        target = overrides.get(artifact.id, artifact.target)
        if PurePosixPath(target).parts[0].casefold().startswith(TEMP_PREFIX):
            raise SyncError(f"artifact {artifact.id} uses a reserved temporary path: {target}")
        for reserved_path in reserved:
            if paths_overlap(target, reserved_path):
                raise SyncError(
                    f"artifact {artifact.id} target overlaps reserved path {reserved_path}: {target}"
                )
        for existing_target, existing_id in targets:
            if paths_overlap(target, existing_target):
                raise SyncError(
                    f"artifact targets overlap for {existing_id} and {artifact.id}: "
                    f"{existing_target}, {target}"
                )
        targets.append((target, artifact.id))
        selected.append((artifact, target))
    return selected


def committed_file(source: Path, revision: str, artifact: Artifact) -> bytes:
    tree_line = run_git(source, "ls-tree", revision, "--", artifact.source)
    assert isinstance(tree_line, str)
    fields = tree_line.strip().split(None, 3)
    if len(fields) != 4 or fields[1] != "blob":
        raise SyncError(f"artifact source is not a committed file: {artifact.source}")
    mode = fields[0]
    expected_mode = "100755" if artifact.executable else "100644"
    if mode != expected_mode:
        raise SyncError(
            f"artifact {artifact.id} has mode {mode}; manifest requires {expected_mode}"
        )
    content = run_git(source, "show", f"{revision}:{artifact.source}", text=False)
    assert isinstance(content, bytes)
    return content


def consumer_root(path: str) -> Path:
    requested = Path(path).resolve()
    if not requested.is_dir():
        raise SyncError(f"consumer directory not found: {requested}")
    top_level = run_git(requested, "rev-parse", "--show-toplevel")
    assert isinstance(top_level, str)
    root = Path(top_level.strip()).resolve()
    if root != requested:
        raise SyncError(f"--consumer must name the repository root: {root}")
    return root


def reject_symlink_path(root: Path, relative: str) -> None:
    current = root
    parts = PurePosixPath(relative).parts
    for index, part in enumerate(parts):
        current = current / part
        if current.is_symlink():
            raise SyncError(f"managed path traverses a symlink: {relative}")
        if index < len(parts) - 1 and current.exists() and not current.is_dir():
            raise SyncError(f"managed path parent is not a directory: {relative}")


def load_previous_paths(lock_path: Path, manifest: Manifest) -> set[str]:
    if not lock_path.exists():
        return set()
    if lock_path.is_symlink() or not lock_path.is_file():
        raise SyncError(f"existing lock is not a regular file: {lock_path}")
    try:
        data = tomllib.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
        raise SyncError(f"cannot read existing sync lock: {exc}") from exc
    required_keys = {
        "version",
        "repository",
        "revision",
        "manifest_sha256",
        "marker_file",
        "profiles",
        "file",
    }
    if set(data) != required_keys or data.get("version") != 1:
        raise SyncError("existing sync lock has invalid top-level fields")
    if data.get("repository") != manifest.repository:
        raise SyncError("existing sync lock names another source repository")
    revision = data.get("revision")
    manifest_hash = data.get("manifest_sha256")
    if (
        not isinstance(revision, str)
        or re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", revision) is None
    ):
        raise SyncError("existing sync lock has an invalid revision")
    if not isinstance(manifest_hash, str) or re.fullmatch(r"[0-9a-f]{64}", manifest_hash) is None:
        raise SyncError("existing sync lock has an invalid manifest hash")
    if data.get("marker_file") != manifest.marker_file:
        raise SyncError("existing sync lock has an unexpected marker path")
    profiles = data.get("profiles")
    if (
        not isinstance(profiles, list)
        or not all(
            isinstance(profile, str) and re.fullmatch(r"[A-Za-z0-9-]+", profile) is not None
            for profile in profiles
        )
        or len(set(profiles)) != len(profiles)
    ):
        raise SyncError("existing sync lock has an invalid profile list")
    files = data.get("file")
    if not isinstance(files, list) or not files:
        raise SyncError("existing sync lock has an invalid file list")
    paths: set[str] = set()
    path_values: list[str] = []
    artifacts: set[str] = set()
    for entry in files:
        if not isinstance(entry, dict) or set(entry) != {
            "artifact",
            "path",
            "sha256",
            "executable",
        }:
            raise SyncError("existing sync lock contains an invalid file entry")
        artifact = entry.get("artifact")
        file_hash = entry.get("sha256")
        executable = entry.get("executable")
        if (
            not isinstance(artifact, str)
            or re.fullmatch(r"[A-Za-z0-9-]+", artifact) is None
            or artifact in artifacts
        ):
            raise SyncError("existing sync lock contains an invalid artifact id")
        if not isinstance(file_hash, str) or re.fullmatch(r"[0-9a-f]{64}", file_hash) is None:
            raise SyncError(f"existing sync lock has an invalid hash for {artifact}")
        if not isinstance(executable, bool):
            raise SyncError(f"existing sync lock has an invalid mode for {artifact}")
        path = validate_path(entry.get("path"), "existing lock path")
        if any(
            paths_overlap(path, reserved)
            for reserved in (manifest.lock_file, manifest.marker_file, PROCESS_LOCK_FILE)
        ) or PurePosixPath(path).parts[0].casefold().startswith(TEMP_PREFIX):
            raise SyncError(f"existing sync lock contains a reserved path: {path}")
        if any(paths_overlap(path, existing) for existing in path_values):
            raise SyncError(f"existing sync lock contains overlapping paths: {path}")
        artifacts.add(artifact)
        path_values.append(path)
        paths.add(path)
    return paths


def render_lock(
    manifest: Manifest,
    revision: str,
    manifest_sha256: str,
    profiles: list[str],
    selected: list[SelectedFile],
) -> bytes:
    lines = [
        "version = 1",
        f"repository = {json.dumps(manifest.repository)}",
        f"revision = {json.dumps(revision)}",
        f"manifest_sha256 = {json.dumps(manifest_sha256)}",
        f"marker_file = {json.dumps(manifest.marker_file)}",
        f"profiles = {json.dumps(sorted(set(profiles)))}",
        "",
    ]
    for item in sorted(selected, key=lambda entry: entry.target):
        lines.extend(
            [
                "[[file]]",
                f"artifact = {json.dumps(item.artifact.id)}",
                f"path = {json.dumps(item.target)}",
                f"sha256 = {json.dumps(item.sha256)}",
                f"executable = {str(item.artifact.executable).lower()}",
                "",
            ]
        )
    return "\n".join(lines).encode("utf-8")


def install_files(
    consumer: Path,
    manifest: Manifest,
    lock_content: bytes,
    selected: list[SelectedFile],
) -> set[str]:
    lock_path = consumer / manifest.lock_file
    marker_path = consumer / manifest.marker_file
    process_lock = consumer / PROCESS_LOCK_FILE
    reject_symlink_path(consumer, manifest.lock_file)
    reject_symlink_path(consumer, manifest.marker_file)
    previous_paths = load_previous_paths(lock_path, manifest)

    try:
        process_lock.mkdir(mode=0o700)
    except FileExistsError as exc:
        raise SyncError(f"another sync may be active: {process_lock}") from exc

    temp_dir: Path | None = None
    marker_created = False
    transaction_resolved = False
    replacements: list[Replacement] = []
    try:
        if marker_path.exists() or marker_path.is_symlink():
            raise SyncError(
                f"an incomplete sync marker exists: {marker_path}; inspect the consumer "
                "before removing it"
            )
        temp_dir = Path(tempfile.mkdtemp(prefix=TEMP_PREFIX, dir=consumer))
        staged: list[tuple[SelectedFile, Path]] = []
        for index, item in enumerate(selected):
            temp_path = temp_dir / str(index)
            temp_path.write_bytes(item.content)
            temp_path.chmod(0o755 if item.artifact.executable else 0o644)
            staged.append((item, temp_path))
        temp_lock = temp_dir / "lock"
        temp_lock.write_bytes(lock_content)
        temp_lock.chmod(0o644)

        marker_path.parent.mkdir(parents=True, exist_ok=True)
        reject_symlink_path(consumer, manifest.marker_file)
        marker_descriptor = os.open(marker_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        marker_created = True
        with os.fdopen(marker_descriptor, "w", encoding="utf-8") as marker:
            marker.write(f"sync in progress\nbackup directory: {temp_dir.name}/previous\n")

        for item, temp_path in staged:
            reject_symlink_path(consumer, item.target)
            destination = consumer.joinpath(*PurePosixPath(item.target).parts)
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists() and not destination.is_file():
                raise SyncError(f"managed target is not a regular file: {item.target}")
            backup = temp_dir / "previous" / item.target
            replacement = Replacement(destination, temp_path, backup)
            replacements.append(replacement)
            if destination.exists():
                backup.parent.mkdir(parents=True, exist_ok=True)
                os.replace(destination, backup)
            os.replace(temp_path, destination)

        lock_path.parent.mkdir(parents=True, exist_ok=True)
        lock_backup = temp_dir / "previous" / manifest.lock_file
        replacements.append(Replacement(lock_path, temp_lock, lock_backup))
        if lock_path.exists():
            lock_backup.parent.mkdir(parents=True, exist_ok=True)
            os.replace(lock_path, lock_backup)
        os.replace(temp_lock, lock_path)
        marker_path.unlink()
        transaction_resolved = True
    except BaseException as exc:
        if marker_created:
            try:
                restore_files(replacements)
                marker_path.unlink()
                transaction_resolved = True
            except (OSError, SyncError) as restore_error:
                assert temp_dir is not None
                raise SyncError(
                    "sync failed and the prior files could not be fully restored; "
                    f"inspect {marker_path} and {temp_dir / 'previous'}: {restore_error}"
                ) from exc
        raise
    finally:
        if temp_dir is not None and (transaction_resolved or not marker_created):
            shutil.rmtree(temp_dir, ignore_errors=True)
        with suppress(OSError):
            process_lock.rmdir()

    return previous_paths - {item.target for item in selected}


def restore_files(replacements: list[Replacement]) -> None:
    failures = []
    for replacement in reversed(replacements):
        try:
            if replacement.backup.exists():
                os.replace(replacement.backup, replacement.destination)
            elif not replacement.staged.exists() and replacement.destination.exists():
                replacement.destination.unlink()
        except OSError as exc:
            failures.append(f"{replacement.destination}: {exc}")
    if failures:
        raise SyncError("; ".join(failures))


def command_list(manifest: Manifest) -> None:
    profiles = sorted({profile for artifact in manifest.artifacts for profile in artifact.profiles})
    print("Profiles:")
    print("  all")
    for profile in profiles:
        print(f"  {profile}")
    print("\nArtifacts:")
    for artifact in manifest.artifacts:
        print(f"  {artifact.id:<28} {artifact.target}")


def command_vendor(
    source: Path,
    revision: str,
    manifest: Manifest,
    manifest_raw: bytes,
    args: argparse.Namespace,
) -> None:
    overrides = parse_target_overrides(args.target)
    choices = select_artifacts(manifest, args.profile, args.artifact, overrides)
    selected: list[SelectedFile] = []
    for artifact, target in choices:
        content = committed_file(source, revision, artifact)
        selected.append(
            SelectedFile(artifact, target, content, hashlib.sha256(content).hexdigest())
        )
    lock_content = render_lock(
        manifest,
        revision,
        hashlib.sha256(manifest_raw).hexdigest(),
        args.profile,
        selected,
    )
    consumer = consumer_root(args.consumer)
    stale_paths = install_files(consumer, manifest, lock_content, selected)
    print(f"Vendored {len(selected)} artifact(s) from {revision}")
    for item in selected:
        print(f"  {item.artifact.id}: {item.target}")
    if stale_paths:
        print("Previously managed paths left unchanged and removed from the lock:")
        for path in sorted(stale_paths):
            print(f"  {path}")


def build_parser(default_source: Path) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Vendor committed Nautilus engineering artifacts")
    parser.add_argument("--source", default=str(default_source), help="source repository checkout")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("list", help="list profiles and artifacts")
    vendor = subparsers.add_parser("vendor", help="vendor selected artifacts into a consumer")
    vendor.add_argument("--consumer", required=True, help="consumer repository root")
    vendor.add_argument("--profile", action="append", default=[], help="profile to vendor")
    vendor.add_argument("--artifact", action="append", default=[], help="artifact id to vendor")
    vendor.add_argument(
        "--target",
        action="append",
        default=[],
        metavar="ARTIFACT=PATH",
        help="override a selected artifact target",
    )
    return parser


def main() -> int:
    default_source = Path(__file__).resolve().parents[1]
    parser = build_parser(default_source)
    args = parser.parse_args()
    try:
        source = Path(args.source).resolve()
        revision = source_revision(source)
        manifest, raw = load_manifest(source, revision)
        if args.command == "list":
            command_list(manifest)
        else:
            command_vendor(source, revision, manifest, raw, args)
    except (OSError, SyncError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
