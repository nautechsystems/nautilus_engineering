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
"""Report consumer adoption locks against the source repository HEAD."""

from __future__ import annotations

import argparse
import re
import sys
import textwrap
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "sync"))

import sync  # noqa: E402


__all__: tuple[str, ...] = ()

REVISION_PATTERN = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
REPORT_WIDTH = 100


def read_lock(lock_path: Path, manifest: sync.Manifest) -> tuple[str, str, set[str]]:
    """Return the locked repository, revision, and artifact ids."""
    try:
        data = tomllib.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
        raise sync.SyncError(f"cannot read sync lock: {exc}") from exc
    repository = data.get("repository")
    revision = data.get("revision")
    files = data.get("file")
    if not isinstance(repository, str) or not repository:
        raise sync.SyncError("lock has an invalid repository")
    if repository != manifest.repository:
        raise sync.SyncError(f"lock names another source repository: {repository}")
    if not isinstance(revision, str) or REVISION_PATTERN.fullmatch(revision) is None:
        raise sync.SyncError("lock has an invalid revision")
    if not isinstance(files, list) or not files:
        raise sync.SyncError("lock has an invalid file list")
    artifacts: set[str] = set()
    for entry in files:
        if not isinstance(entry, dict) or not isinstance(entry.get("artifact"), str):
            raise sync.SyncError("lock contains an invalid file entry")
        artifacts.add(entry["artifact"])
    sync.load_locked_selection(lock_path, manifest)
    return repository, revision, artifacts


def consumer_status(
    manifest: sync.Manifest,
    sources: dict[str, str],
    consumer: Path,
) -> tuple[list[str], bool]:
    """Return the report lines for one consumer and whether it is behind."""
    lock_path = consumer / manifest.lock_file
    if not lock_path.is_file():
        raise sync.SyncError(f"sync lock not found: {lock_path}")
    _, lock_revision, locked = read_lock(lock_path, manifest)
    short = lock_revision[:7]
    try:
        sync.run_git(ROOT, "cat-file", "-e", f"{lock_revision}^{{commit}}")
    except sync.SyncError as exc:
        raise sync.SyncError(
            f"lock revision {short} is not in this checkout; fetch before reporting",
        ) from exc
    try:
        sync.run_git(ROOT, "merge-base", "--is-ancestor", lock_revision, "HEAD")
    except sync.SyncError as exc:
        raise sync.SyncError(f"lock revision {short} is not an ancestor of HEAD") from exc
    behind = int(sync.run_git(ROOT, "rev-list", "--count", f"{lock_revision}..HEAD").strip())

    lines: list[str] = []
    if behind == 0:
        lines.append(f"{short}  current")
    else:
        lines.append(f"{short}  {behind} commit(s) behind")
        changed = changed_artifacts(lock_revision, sources, locked)
        if changed:
            lines.extend(wrap_artifacts("changed", changed))
    removed = sorted(locked - sources.keys())
    if removed:
        lines.extend(wrap_artifacts("removed from manifest", removed))
    unadopted = sorted(sources.keys() - locked)
    if unadopted:
        lines.extend(wrap_artifacts("unadopted", unadopted))
    return lines, behind > 0


def wrap_artifacts(label: str, artifacts: list[str]) -> list[str]:
    initial = f"  {label} ({len(artifacts)}): "
    return textwrap.wrap(
        ", ".join(artifacts),
        width=REPORT_WIDTH,
        initial_indent=initial,
        subsequent_indent=" " * len(initial),
        break_long_words=False,
        break_on_hyphens=False,
    )


def changed_artifacts(
    lock_revision: str,
    sources: dict[str, str],
    locked: set[str],
) -> list[str]:
    paths = sorted({sources[artifact] for artifact in locked if artifact in sources})
    if not paths:
        return []
    output = sync.run_git(ROOT, "diff", "--name-only", lock_revision, "HEAD", "--", *paths)
    changed_paths = {line.strip() for line in output.splitlines() if line.strip()}
    return sorted(
        artifact
        for artifact in locked
        if artifact in sources and sources[artifact] in changed_paths
    )


def _write(message: str, *, error: bool = False) -> None:
    stream = sys.stderr if error else sys.stdout
    stream.write(f"{message}\n")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Report consumer adoption locks against the source repository HEAD",
    )
    parser.add_argument(
        "consumer",
        nargs="*",
        help="consumer repository roots",
    )
    args = parser.parse_args()
    if not args.consumer:
        _write("Error: specify at least one consumer repository root", error=True)
        return 2
    try:
        revision = sync.source_revision(ROOT)
        manifest, _ = sync.load_manifest(ROOT, revision)
    except (OSError, sync.SyncError) as exc:
        _write(f"Error: {exc}", error=True)
        return 2
    consumers = [Path(argument).resolve() for argument in args.consumer]

    sources = {artifact.id: artifact.source for artifact in manifest.artifacts}
    _write(f"Adoption status for {len(consumers)} consumer(s) against {revision[:7]}")
    _write("")
    width = max(len(consumer.name) for consumer in consumers)
    behind_count = 0
    error_count = 0
    previous_details = False
    for index, consumer in enumerate(consumers):
        try:
            lines, behind = consumer_status(manifest, sources, consumer)
        except (OSError, sync.SyncError) as exc:
            error_count += 1
            lines, behind = [f"error: {exc}"], False
        if behind:
            behind_count += 1
        if index and (previous_details or len(lines) > 1):
            _write("")
        _write(f"{consumer.name:<{width}}  {lines[0]}")
        for line in lines[1:]:
            _write(line)
        previous_details = len(lines) > 1
    _write("")

    if error_count:
        _write(f"{error_count} consumer report(s) failed", error=True)
        return 2
    if behind_count:
        _write(f"{behind_count} of {len(consumers)} consumer(s) are behind {revision[:7]}")
        return 1
    _write(f"All {len(consumers)} consumer(s) are current at {revision[:7]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
