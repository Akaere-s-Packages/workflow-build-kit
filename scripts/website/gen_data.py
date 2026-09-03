#!/usr/bin/env python3
"""Generate WebSite-Kit's src/_data/{packages.json,stats.json,updates.json}
and src/_data/packageDetails/<name>.json from the Registry + this run's
build artifacts.

Every run refreshes AUR-sourced fields (description, url, licenses,
maintainer, submitter, votes, popularity, first_submitted) for every
tracked package from one batched AUR RPC call — that data is cheap and
small, and keeping it fresh for the *whole* registry (not just whatever
happened to be rebuilt) is what makes stats.json/required_by honest.

Build-derived fields (files, package_size_bytes, dependencies with repo
classification, packager, build_status, build_run_url, last_updated,
version) only change for packages this run actually (re)built — everyone
else keeps whatever is already committed in the WebSite-Kit checkout, so a
build failure never overwrites the last known-good published state, and
"last_updated" genuinely means "last time we published", not "last time
this script ran".

Usage:
  gen_data.py --registry-root <Registry checkout>
              --website-data-dir <WebSite-Kit checkout>/src/_data
              [--built <built_packages.json>]

built_packages.json (written by the calling workflow, one entry per
package the `build` job touched this run):
  [{"type","name","pkgbase","build_status","job_url","artifact_dir"}, ...]
build_status is one of: published | build_failed | publish_failed
artifact_dir must contain file_list.json and build_meta.json when
build_status == "published" (see build/package.sh).
"""
import argparse
import datetime
import json
import pathlib
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore

AUR_RPC = "https://aur.archlinux.org/rpc/v5/info"
DATE_FMT = "%Y-%m-%dT%H:%M:%SZ"


def iso(ts: int) -> str:
    return datetime.datetime.fromtimestamp(ts, tz=datetime.timezone.utc).strftime(DATE_FMT)


def now_iso() -> str:
    return datetime.datetime.now(tz=datetime.timezone.utc).strftime(DATE_FMT)


def parse_iso(s: str) -> datetime.datetime:
    return datetime.datetime.strptime(s, DATE_FMT).replace(tzinfo=datetime.timezone.utc)


def fetch_aur_info(names: list[str]) -> dict[str, dict]:
    """One batched AUR RPC call, queried by package *name* (not pkgbase —
    a split PKGBUILD's several pkgnames each have their own Depends/
    MakeDepends/description/etc, and AUR RPC's info action is queryable by
    the specific name). Returns a dict keyed by that same name."""
    if not names:
        return {}
    qs = "&".join("arg[]=" + urllib.parse.quote(n) for n in sorted(set(names)))
    try:
        with urllib.request.urlopen(f"{AUR_RPC}?{qs}", timeout=30) as resp:
            data = json.load(resp)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        print(f"::warning::AUR RPC lookup failed, continuing with stale AUR-sourced fields: {exc}", file=sys.stderr)
        return {}
    return {r["Name"]: r for r in data.get("results", [])}


def load_registry(registry_root: pathlib.Path) -> list[dict]:
    # Layout: <distro>/<type>/<name>/<name>.toml (e.g. archlinux/aur/asusctl/asusctl.toml).
    entries = []
    for toml_path in sorted(registry_root.glob("*/*/*/*.toml")):
        distro, source_type, dirname, filename = toml_path.parts[-4:]
        if filename != f"{dirname}.toml":
            continue
        table = tomllib.loads(toml_path.read_text())["PACKAGES"]
        entries.append(
            {
                "distro": distro,
                "type": source_type,
                "name": table["name"],
                "pkgbase": table.get("pkgbase", table["name"]),
                "version": table["version"],
                "autoupdate": bool(table.get("autoupdate", False)),
                "toml_path": toml_path,
            }
        )
    return entries


def first_added_date(registry_root: pathlib.Path, toml_path: pathlib.Path) -> str | None:
    """First commit date this file was added to the Registry repo, or None
    if that can't be determined (e.g. shallow checkout)."""
    rel = toml_path.relative_to(registry_root)
    try:
        out = subprocess.run(
            ["git", "-C", str(registry_root), "log", "--follow", "--diff-filter=A", "--format=%aI", "--", str(rel)],
            capture_output=True, text=True, timeout=15,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    lines = [l for l in out.stdout.splitlines() if l.strip()]
    if not lines:
        return None
    # git log lists newest-first; the *first add* is the oldest entry.
    earliest = lines[-1]
    return datetime.datetime.fromisoformat(earliest).astimezone(datetime.timezone.utc).strftime(DATE_FMT)


def build_detail(entry: dict, aur: dict, built: dict | None, existing: dict | None) -> dict:
    name = entry["name"]

    build_meta: dict = {}
    file_list: dict = {}
    if built is not None and built.get("build_status") == "published":
        artifact_dir = pathlib.Path(built["artifact_dir"])
        fl_path = artifact_dir / "file_list.json"
        bm_path = artifact_dir / "build_meta.json"
        file_list = json.loads(fl_path.read_text()) if fl_path.exists() else {}
        build_meta = json.loads(bm_path.read_text()) if bm_path.exists() else {}

    detail = dict(existing) if existing else {}

    detail["name"] = name
    detail["pkgbase"] = entry["pkgbase"]
    detail["distro"] = entry["distro"]
    detail["source_type"] = entry["type"]

    # AUR-sourced fields: always refreshed (cheap, batched, keeps the whole
    # registry's social/metadata honest even for packages we didn't touch).
    detail["maintainer"] = aur.get("Maintainer")
    detail["submitter"] = aur.get("Submitter")
    detail["votes"] = aur.get("NumVotes")
    detail["popularity"] = aur.get("Popularity")
    detail["first_submitted"] = iso(aur["FirstSubmitted"]) if aur.get("FirstSubmitted") else detail.get("first_submitted")
    # Prefer our own build's .PKGINFO (what we actually shipped) over AUR's
    # PKGBUILD-in-general description/url/licenses when we have it fresh.
    detail["description"] = build_meta.get("description") or aur.get("Description") or detail.get("description")
    detail["url"] = build_meta.get("url") or aur.get("URL") or detail.get("url")
    detail["licenses"] = build_meta.get("licenses") or aur.get("License") or detail.get("licenses") or []

    if built is None:
        # Untouched this run: everything build-derived stays as it was.
        detail.setdefault("version", entry["version"])
        detail.setdefault("build_status", "unknown")
        detail.setdefault("build_run_url", None)
        detail.setdefault("package_size_bytes", None)
        detail.setdefault("dependencies", [])
        detail.setdefault("sources", [])
        detail.setdefault("files", [])
        detail.setdefault("last_updated", None)
        detail.setdefault("packager", None)
        return detail

    detail["build_status"] = built["build_status"]
    detail["build_run_url"] = built.get("job_url")

    if built["build_status"] == "published":
        # A real, successful publish this run: everything build-derived
        # (and last_updated) moves forward.
        detail["version"] = entry["version"]
        detail["last_updated"] = now_iso()
        detail["packager"] = build_meta.get("packager")
        detail["dependencies"] = build_meta.get("dependencies", [])
        detail["package_size_bytes"] = file_list.get("package_size_bytes")
        detail["files"] = file_list.get("files", [])
        detail.setdefault("sources", [])
    else:
        # Build or publish failed: report the failure, but do NOT pretend
        # the new version shipped — keep whatever was last actually
        # published (may be nothing, if this package has never succeeded).
        detail.setdefault("version", entry["version"])
        detail.setdefault("last_updated", None)
        detail.setdefault("packager", None)
        detail.setdefault("dependencies", [])
        detail.setdefault("sources", [])
        detail.setdefault("files", [])
        detail.setdefault("package_size_bytes", None)

    return detail


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry-root", required=True, type=pathlib.Path)
    ap.add_argument("--website-data-dir", required=True, type=pathlib.Path, help="path to WebSite-Kit's src/_data")
    ap.add_argument("--built", type=pathlib.Path, help="path to this run's built_packages.json manifest")
    args = ap.parse_args()

    registry_entries = load_registry(args.registry_root)
    built_list = json.loads(args.built.read_text()) if args.built and args.built.exists() else []
    built_by_name = {b["name"]: b for b in built_list}

    details_dir = args.website_data_dir / "packageDetails"
    details_dir.mkdir(parents=True, exist_ok=True)

    # Fetch AUR RPC info keyed by package *name*, not pkgbase: a split
    # PKGBUILD (one pkgbase, several pkgnames — e.g. asusctl also builds
    # rog-control-center) gives each pkgname its own Depends/MakeDepends,
    # and AUR RPC's info action is queryable by the specific pkgname, not
    # just the pkgbase. Keying by pkgbase here would make every package
    # sharing a pkgbase silently inherit one of them's dependency list.
    aur_by_name = fetch_aur_info([e["name"] for e in registry_entries])

    # required_by: reverse-map of AUR's own Depends/OptDepends/MakeDepends
    # across every tracked package, restricted to names we ourselves track.
    tracked_names = {e["name"] for e in registry_entries}
    required_by: dict[str, list[str]] = {n: [] for n in tracked_names}
    for entry in registry_entries:
        info = aur_by_name.get(entry["name"], {})
        deps = set(info.get("Depends", [])) | set(info.get("OptDepends", [])) | set(info.get("MakeDepends", []))
        for dep in deps:
            dep_name = dep.split(":", 1)[0].strip()
            for sep in (">=", "<=", "=", ">", "<"):
                dep_name = dep_name.split(sep, 1)[0]
            if dep_name in tracked_names and dep_name != entry["name"]:
                required_by[dep_name].append(entry["name"])

    packages_summary = []
    updates = []
    maintainers: set[str] = set()
    orphan_count = 0
    added_7_days = 0
    never_updated = 0
    outdated = 0

    now = datetime.datetime.now(tz=datetime.timezone.utc)
    week_ago = now - datetime.timedelta(days=7)
    year_ago = now - datetime.timedelta(days=365)
    updated_7_days = 0
    updated_year = 0

    for entry in registry_entries:
        name = entry["name"]
        existing_path = details_dir / f"{name}.json"
        existing = json.loads(existing_path.read_text()) if existing_path.exists() else None
        aur = aur_by_name.get(entry["name"], {})

        detail = build_detail(entry, aur, built_by_name.get(name), existing)
        detail["required_by"] = [{"name": n} for n in sorted(required_by.get(name, []))]
        existing_path.write_text(json.dumps(detail, indent=2) + "\n")

        if detail.get("maintainer"):
            maintainers.add(detail["maintainer"])
        else:
            orphan_count += 1

        added = first_added_date(args.registry_root, entry["toml_path"])
        if added and parse_iso(added) >= week_ago:
            added_7_days += 1

        if detail["build_status"] == "unknown":
            never_updated += 1

        if detail.get("last_updated"):
            when = parse_iso(detail["last_updated"])
            if when >= week_ago:
                updated_7_days += 1
            if when >= year_ago:
                updated_year += 1

        aur_version = aur.get("Version")
        if aur_version and aur_version != detail.get("version"):
            outdated += 1

        packages_summary.append(
            {
                "name": name,
                "pkgbase": entry["pkgbase"],
                "distro": entry["distro"],
                "source_type": entry["type"],
                "version": detail.get("version"),
                "description": detail.get("description"),
                "maintainer": detail.get("maintainer"),
                "last_updated": detail.get("last_updated"),
                "build_status": detail["build_status"],
                "detail_url": f"/packages/{name}/",
            }
        )
        if detail.get("last_updated"):
            updates.append({"name": name, "version": detail["version"], "date": detail["last_updated"]})

    packages_summary.sort(key=lambda p: p["name"])
    (args.website_data_dir / "packages.json").write_text(json.dumps(packages_summary, indent=2) + "\n")

    updates.sort(key=lambda u: u["date"], reverse=True)
    (args.website_data_dir / "updates.json").write_text(json.dumps(updates[:20], indent=2) + "\n")

    stats = {
        "packages": len(registry_entries),
        "orphan_packages": orphan_count,
        "added_7_days": added_7_days,
        "updated_7_days": updated_7_days,
        "updated_year": updated_year,
        "never_updated": never_updated,
        # Single-maintainer curated repo: these two are aurweb-parity
        # fields with no real per-user meaning here, kept as honest
        # constants rather than faked social-network numbers.
        "registered_users": 1,
        "package_maintainers": len(maintainers),
        "my_packages": len(registry_entries),
        "my_outdated": outdated,
    }
    (args.website_data_dir / "stats.json").write_text(json.dumps(stats, indent=2) + "\n")

    print(f"wrote packages.json ({len(packages_summary)}), updates.json, stats.json, and {len(registry_entries)} packageDetails/*.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
