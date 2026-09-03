#!/usr/bin/env python3
"""Regenerate the package table in Registry/README.md between the
PACKAGE_TABLE:START/END markers, leaving the rest of the file untouched.

README.md must already contain both marker lines once, by hand, before
the first run — this script only ever replaces what's between them.

Usage:
  update_readme.py --registry-root <Registry checkout>
                    [--website-data-dir <WebSite-Kit checkout>/src/_data]
                    [--pages-domain packages.pysio.online]
"""
import argparse
import json
import pathlib
import sys

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore

START = "<!-- PACKAGE_TABLE:START -->"
END = "<!-- PACKAGE_TABLE:END -->"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry-root", required=True, type=pathlib.Path)
    ap.add_argument("--website-data-dir", type=pathlib.Path, help="WebSite-Kit src/_data, for last_updated (optional)")
    ap.add_argument("--pages-domain", default="", help="e.g. packages.pysio.online, for detail links")
    args = ap.parse_args()

    readme_path = args.registry_root / "README.md"
    if not readme_path.exists() or START not in readme_path.read_text() or END not in readme_path.read_text():
        print(
            f"::error::README.md must already contain a {START} / {END} marker pair "
            "before this script can run; add them once by hand first.",
            file=sys.stderr,
        )
        return 1

    text = readme_path.read_text()

    details: dict[str, dict] = {}
    if args.website_data_dir:
        details_dir = args.website_data_dir / "packageDetails"
        if details_dir.is_dir():
            for p in details_dir.glob("*.json"):
                details[p.stem] = json.loads(p.read_text())

    rows = []
    for toml_path in sorted(args.registry_root.glob("*/*/*/*.toml")):
        distro, source_type, dirname, filename = toml_path.parts[-4:]
        if filename != f"{dirname}.toml":
            continue
        table = tomllib.loads(toml_path.read_text())["PACKAGES"]
        name = table["name"]
        detail = details.get(name, {})
        last_updated = (detail.get("last_updated") or "")[:10] or "-"
        autoupdate = "yes" if table.get("autoupdate") else "no"
        base = f"https://{args.pages_domain}" if args.pages_domain else ""
        link = f"{base}/packages/{name}/"
        rows.append(f"| {name} | {distro} | {source_type} | {table['version']} | {autoupdate} | {last_updated} | [details]({link}) |")

    table_md = "\n".join(
        [
            "| Package | Distro | Source | Version | Autoupdate | Last Updated | Details |",
            "|---|---|---|---|---|---|---|",
            *rows,
        ]
    )

    before, _, rest = text.partition(START)
    _, _, after = rest.partition(END)
    new_text = f"{before}{START}\n{table_md}\n{END}{after}"

    if new_text == text:
        print("README.md package table already up to date")
        return 0

    readme_path.write_text(new_text)
    print(f"updated README.md package table ({len(rows)} packages)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
