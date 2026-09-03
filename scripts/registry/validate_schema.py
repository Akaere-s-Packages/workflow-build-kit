#!/usr/bin/env python3
"""Validate Registry package TOML files against the aur/ schema.

Meant to run as the first, secret-free step of pr-preview.yml so a
malformed toml fails fast before any build is attempted.

Usage: validate_schema.py <toml-path> [<toml-path> ...]
Paths are expected relative to the Registry repo root, shaped
<distro>/<type>/<name>/<name>.toml (e.g. archlinux/aur/asusctl/asusctl.toml).
"""
import pathlib
import sys

try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:  # pragma: no cover - CI always has 3.11+
    import tomli as tomllib  # type: ignore


def validate(raw_path: str) -> list[str]:
    path = pathlib.Path(raw_path)
    errors: list[str] = []

    parts = path.parts[-4:]
    if len(parts) != 4:
        return [f"{path}: expected a path shaped <distro>/<type>/<name>/<name>.toml"]
    _distro, _source_type, dirname, filename = parts

    if filename != f"{dirname}.toml":
        errors.append(f"{path}: file name must match its directory name ({dirname}.toml)")

    try:
        data = tomllib.loads(path.read_text())
    except (OSError, tomllib.TOMLDecodeError) as exc:
        errors.append(f"{path}: invalid TOML ({exc})")
        return errors

    table = data.get("PACKAGES")
    if table is None:
        errors.append(f"{path}: missing [PACKAGES] table")
        return errors

    name = table.get("name")
    if not isinstance(name, str) or not name:
        errors.append(f"{path}: 'name' must be a non-empty string")
    elif name != dirname:
        errors.append(f"{path}: 'name' ({name!r}) must match the directory name ({dirname!r})")

    version = table.get("version")
    if not isinstance(version, str) or "-" not in version:
        errors.append(f"{path}: 'version' must be a string shaped pkgver-pkgrel")

    if not isinstance(table.get("autoupdate"), bool):
        errors.append(f"{path}: 'autoupdate' must be a bool")

    if "enabled" in table and not isinstance(table["enabled"], bool):
        errors.append(f"{path}: 'enabled' must be a bool")

    if "pkgbase" in table and not isinstance(table["pkgbase"], str):
        errors.append(f"{path}: 'pkgbase' must be a string")

    if "aur_depends" in table:
        deps = table["aur_depends"]
        if not isinstance(deps, list) or not all(isinstance(d, str) for d in deps):
            errors.append(f"{path}: 'aur_depends' must be a list of strings")

    if "notes" in table and not isinstance(table["notes"], str):
        errors.append(f"{path}: 'notes' must be a string")

    return errors


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: validate_schema.py <toml-path> [...]", file=sys.stderr)
        return 2

    all_errors: list[str] = []
    for raw in argv:
        all_errors.extend(validate(raw))

    for err in all_errors:
        print(f"::error::{err}")

    if not all_errors:
        print(f"ok: {len(argv)} package file(s) validated")

    return 1 if all_errors else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
