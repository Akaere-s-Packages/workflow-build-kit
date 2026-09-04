#!/usr/bin/env python3
"""Generate WebSite-Kit's src/_data/{packages.json,stats.json,updates.json}
and src/_data/packageDetails/<name>.json from the Registry + this run's
build artifacts.

Every run refreshes AUR-sourced fields (description, url, licenses,
maintainer, submitter, votes, popularity, first_submitted) for every
tracked package from one batched AUR RPC call, then refreshes each package's
source list from its pkgbase's .SRCINFO.

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
  [{"type","name","pkgbase","build_status","job_url","artifact_dir",
    "filename","sha256"}, ...]
build_status is one of: published | build_failed | publish_failed
artifact_dir must contain file_list.json and build_meta.json when
build_status == "published" (see build/package.sh). filename/sha256 are
the exact published package file's name and digest — set only when this
package was actually signed and uploaded this run (see publish_all.sh),
null otherwise. Passed straight through to packageDetails/<name>.json so
the website can point users at `gh attestation verify <filename> --repo
...` for the GitHub Artifact Attestation build-publish.yml's publish job
generates for that same file.
"""
import argparse
import datetime
import json
import pathlib
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "registry"))
import aur_graph  # noqa: E402

DATE_FMT = "%Y-%m-%dT%H:%M:%SZ"


def iso(ts: int) -> str:
    return datetime.datetime.fromtimestamp(ts, tz=datetime.timezone.utc).strftime(DATE_FMT)


def now_iso() -> str:
    return datetime.datetime.now(tz=datetime.timezone.utc).strftime(DATE_FMT)


def parse_iso(s: str) -> datetime.datetime:
    return datetime.datetime.strptime(s, DATE_FMT).replace(tzinfo=datetime.timezone.utc)


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



def parse_sources(srcinfo: str) -> list[dict[str, str]]:
    """Return displayable source metadata from a pkgbase's .SRCINFO."""
    sources: list[dict[str, str]] = []
    seen: set[tuple[str, str | None]] = set()

    for line in srcinfo.splitlines():
        key, separator, value = line.partition(" = ")
        key = key.strip()
        if not separator or (key != "source" and not key.startswith("source_")):
            continue

        name, alias, location = "", "", value.strip()
        if "::" in location:
            alias, _, location = location.partition("::")
            alias = alias.strip()
            location = location.strip()

        for vcs_prefix in ("git+", "hg+", "svn+", "bzr+"):
            if location.startswith(vcs_prefix):
                location = location.removeprefix(vcs_prefix)
                break

        url = location if location.startswith(("https://", "http://", "ftp://")) else None
        if alias:
            name = alias
        elif url:
            name = url.split("#", 1)[0].rstrip("/").rsplit("/", 1)[-1]
        else:
            name = location

        entry = (name, url)
        if name and entry not in seen:
            sources.append({"name": name, **({"url": url} if url else {})})
            seen.add(entry)

    return sources


def fetch_srcinfo_sources(pkgbase: str) -> list[dict[str, str]] | None:
    """Fetch a pkgbase's source declarations, preserving stale data on failure."""
    url = "https://aur.archlinux.org/cgit/aur.git/plain/.SRCINFO?h=" + urllib.parse.quote(pkgbase)
    last_exc: Exception | None = None

    for attempt in range(1, aur_graph.RETRY_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                return parse_sources(response.read().decode("utf-8"))
        except (OSError, UnicodeDecodeError) as exc:
            last_exc = exc
            if attempt < aur_graph.RETRY_ATTEMPTS:
                print(
                    f"::warning::.SRCINFO lookup for {pkgbase} failed "
                    f"(attempt {attempt}/{aur_graph.RETRY_ATTEMPTS}), retrying in "
                    f"{aur_graph.RETRY_DELAY_SECONDS}s: {exc}",
                    file=sys.stderr,
                )
                time.sleep(aur_graph.RETRY_DELAY_SECONDS)

    print(
        f"::warning::.SRCINFO lookup for {pkgbase} failed after "
        f"{aur_graph.RETRY_ATTEMPTS} attempts; retaining prior sources: {last_exc}",
        file=sys.stderr,
    )
    return None


def build_detail(
    entry: dict,
    aur: dict,
    built: dict | None,
    existing: dict | None,
    sources: list[dict[str, str]] | None,
) -> dict:
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

    if sources is not None:
        detail["sources"] = sources

    if built is None:
        detail.setdefault("version", entry["version"])
        detail.setdefault("build_status", "unknown")
        detail.setdefault("build_run_url", None)
        detail.setdefault("package_size_bytes", None)
        detail.setdefault("dependencies", [])
        detail.setdefault("sources", [])
        detail.setdefault("files", [])
        detail.setdefault("last_updated", None)
        detail.setdefault("packager", None)
        detail.setdefault("filename", None)
        detail.setdefault("sha256", None)
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
        detail["filename"] = built.get("filename")
        detail["sha256"] = built.get("sha256")
        detail.setdefault("sources", [])
    else:
        # Build or publish failed: report the failure, but do NOT pretend
        # the new version shipped — keep whatever was last actually
        # published (may be nothing, if this package has never succeeded).
        # filename/sha256 deliberately NOT kept from a prior successful
        # publish here: publish_failed in particular can mean the file did
        # upload to R2 but the db never picked it up (see publish_all.sh),
        # so the last *attested* file may not be the one currently live —
        # safer to show nothing than a filename that might not verify.
        detail.setdefault("version", entry["version"])
        detail.setdefault("last_updated", None)
        detail.setdefault("packager", None)
        detail.setdefault("dependencies", [])
        detail.setdefault("sources", [])
        detail.setdefault("files", [])
        detail.setdefault("package_size_bytes", None)
        detail["filename"] = None
        detail["sha256"] = None

    return detail


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry-root", required=True, type=pathlib.Path)
    ap.add_argument("--website-data-dir", required=True, type=pathlib.Path, help="path to WebSite-Kit's src/_data")
    ap.add_argument("--built", type=pathlib.Path, help="path to this run's built_packages.json manifest")
    args = ap.parse_args()

    registry_entries = aur_graph.load_registry(args.registry_root)
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
    aur_by_name = aur_graph.fetch_aur_info([e["name"] for e in registry_entries])

    # Sources are common to split packages, so fetch each pkgbase once.
    sources_by_pkgbase = {
        pkgbase: fetch_srcinfo_sources(pkgbase)
        for pkgbase in sorted({entry["pkgbase"] for entry in registry_entries})
    }
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
        aur = aur_by_name.get(name, {})

        detail = build_detail(entry, aur, built_by_name.get(name), existing, sources_by_pkgbase[entry["pkgbase"]])
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
