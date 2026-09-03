#!/usr/bin/env python3
"""Stage build artifacts under names accepted by GitHub Actions artifacts."""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

MAP_FILENAME = "artifact-name-map.json"
UNSAFE_CHARACTERS = frozenset('"%<>:|?*')


def artifact_safe_name(name: str) -> str:
    """Encode characters rejected by actions/upload-artifact on Windows."""
    return "".join(
        f"%{ord(character):02X}"
        if character in UNSAFE_CHARACTERS or ord(character) < 32
        else character
        for character in name
    )


def validate_filename(name: str) -> None:
    if not name or Path(name).name != name or name in {".", ".."}:
        raise ValueError(f"invalid artifact filename: {name!r}")


def stage(source_dir: Path, artifact_dir: Path) -> None:
    if not source_dir.is_dir():
        raise ValueError(f"source directory does not exist: {source_dir}")
    if artifact_dir.exists() and any(artifact_dir.iterdir()):
        raise ValueError(f"artifact directory must be empty: {artifact_dir}")

    artifact_dir.mkdir(parents=True, exist_ok=True)
    name_map: dict[str, str] = {}

    for source in sorted(source_dir.iterdir()):
        if not source.is_file():
            raise ValueError(f"artifact source must be a file: {source}")
        if source.name == MAP_FILENAME:
            raise ValueError(f"reserved artifact filename: {source.name}")

        staged_name = artifact_safe_name(source.name)
        if staged_name != source.name:
            name_map[staged_name] = source.name
        shutil.copy2(source, artifact_dir / staged_name)

    (artifact_dir / MAP_FILENAME).write_text(
        json.dumps({"files": name_map}, sort_keys=True), encoding="utf-8"
    )


def restore(artifact_dir: Path) -> None:
    map_path = artifact_dir / MAP_FILENAME
    if not map_path.exists():
        return

    try:
        name_map = json.loads(map_path.read_text(encoding="utf-8"))["files"]
    except (json.JSONDecodeError, KeyError, TypeError) as error:
        raise ValueError(f"invalid artifact name map: {map_path}") from error
    if not isinstance(name_map, dict):
        raise ValueError(f"invalid artifact name map: {map_path}")

    for staged_name, original_name in name_map.items():
        if not isinstance(staged_name, str) or not isinstance(original_name, str):
            raise ValueError(f"invalid artifact name map: {map_path}")
        validate_filename(staged_name)
        validate_filename(original_name)

        staged_path = artifact_dir / staged_name
        original_path = artifact_dir / original_name
        if not staged_path.is_file():
            raise ValueError(f"staged artifact file does not exist: {staged_path}")
        if original_path.exists():
            raise ValueError(f"original artifact path already exists: {original_path}")
        staged_path.rename(original_path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("stage", "restore"))
    parser.add_argument("source_dir", type=Path)
    parser.add_argument("artifact_dir", type=Path, nargs="?")
    args = parser.parse_args()

    if args.operation == "stage":
        if args.artifact_dir is None:
            parser.error("stage requires SOURCE_DIR and ARTIFACT_DIR")
        stage(args.source_dir, args.artifact_dir)
    else:
        if args.artifact_dir is not None:
            parser.error("restore requires only ARTIFACT_DIR")
        restore(args.source_dir)


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
