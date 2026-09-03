#!/usr/bin/env bash
set -euo pipefail

# Builds one AUR package with makepkg and emits, into $out_dir:
#   <name>-<version>-x86_64.pkg.tar.zst   the built package
#   file_list.json                        {"package_size_bytes": N, "files": [...]}
#   build_meta.json                       {"description","url","licenses","packager","dependencies":[...]}
#
# Must run as root inside archlinux:base-devel (or equivalent) — it creates
# a throwaway non-root user internally because makepkg refuses to run as
# root.
#
# Usage: package.sh <name> <pkgbase> <out-dir> [aur_depends...]
#
# aur_depends are other AUR packages (not in the official repos) that must
# be built and installed into the container before <pkgbase> itself, for
# packages with chained AUR-only dependencies.

name="${1:?package name required}"
pkgbase="${2:?pkgbase required}"
out_dir="${3:?output dir required}"
shift 3
aur_depends=("$@")

work_dir=/tmp/build
mkdir -p "$work_dir" "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

# Network-bound steps (pacman mirror sync, cloning from aur.archlinux.org)
# fail transiently often enough in CI — a mirror hiccup, a brief DNS
# blip, AUR itself being momentarily slow — that failing the whole build
# on the first attempt wastes a build slot on something that would have
# just worked on retry. Real, non-transient failures (bad pkgbase, actual
# build errors) still fail loudly after exhausting the attempts.
retry() {
  local attempts=3 delay=5 n=1
  until "$@"; do
    if (( n >= attempts )); then
      echo "::error::command failed after $attempts attempts: $*" >&2
      return 1
    fi
    echo "::warning::command failed (attempt $n/$attempts), retrying in ${delay}s: $*" >&2
    sleep "$delay"
    n=$((n + 1))
  done
}

retry pacman -Sy --noconfirm --needed git

if ! id builder &>/dev/null; then
  useradd -m builder
  echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
fi
chown -R builder:builder "$work_dir"

export PACKAGER="Lilithya <me@lilithya.su>"

build_one() {
  local base="$1"
  local dir="$work_dir/$base"
  rm -rf "$dir"
  # `su - builder` (with the dash) matters: without it $HOME stays /root,
  # which builder can't write to, and makepkg/git fail outright.
  retry su - builder -c "rm -rf '$dir' && git clone --depth 1 'https://aur.archlinux.org/${base}.git' '$dir'"

  # A PKGBUILD that declares validpgpkeys expects those upstream release
  # keys to already be in the builder's keyring before makepkg verifies
  # the downloaded source's detached signature — but every build starts
  # from a completely fresh container, so that key is never there yet.
  # .SRCINFO lists the full fingerprint(s) makepkg actually needs (AUR
  # requires it to be kept in sync with the PKGBUILD).
  local skip_pgp_check=""
  local keys
  keys="$(grep -oP '(?<=validpgpkeys = )[0-9A-Fa-f]+' "$dir/.SRCINFO" 2>/dev/null | tr '\n' ' ')"
  if [[ -n "$keys" ]]; then
    local imported=false
    for ks in keyserver.ubuntu.com keys.openpgp.org pgp.mit.edu; do
      if su - builder -c "gpg --keyserver $ks --keyserver-options timeout=15 --recv-keys $keys" &>/dev/null; then
        imported=true
        break
      fi
    done
    if [[ "$imported" != true ]]; then
      echo "::warning::couldn't fetch PGP key(s) [$keys] for $base from any keyserver — building with --skippgpcheck" >&2
      skip_pgp_check="--skippgpcheck"
    fi
  fi

  su - builder -c "cd '$dir' && PACKAGER='$PACKAGER' makepkg -s --noconfirm --needed $skip_pgp_check"
}

# Chained AUR-only dependencies must be built and installed into the
# container first — makepkg --syncdeps only knows how to pull from pacman
# sync repos, not from AUR.
for dep in "${aur_depends[@]:-}"; do
  [[ -z "$dep" ]] && continue
  build_one "$dep"
  dep_pkg=$(find "$work_dir/$dep" -maxdepth 1 -name '*.pkg.tar.zst' | head -n1)
  su - builder -c "sudo pacman -U --noconfirm '$dep_pkg'"
done

build_one "$pkgbase"

# A PKGBUILD can produce more than one pkgname; this Registry entry only
# tracks the one named $name.
shopt -s nullglob
matches=("$work_dir/$pkgbase/${name}-"*-x86_64.pkg.tar.zst)
shopt -u nullglob
if [[ ${#matches[@]} -ne 1 ]]; then
  echo "expected exactly one built package matching '${name}-*-x86_64.pkg.tar.zst' in $work_dir/$pkgbase, found ${#matches[@]}" >&2
  exit 1
fi
pkg_file="${matches[0]}"
cp "$pkg_file" "$out_dir/"

# --- file list + total size, excluding directories and pacman's own
#     bookkeeping entries (.PKGINFO, .MTREE, .BUILDINFO, .INSTALL) ---
python3 - "$pkg_file" "$out_dir/file_list.json" <<'PY'
import json
import subprocess
import sys

pkg_path, out_path = sys.argv[1], sys.argv[2]
listing = subprocess.run(
    ["bsdtar", "-tvf", pkg_path], capture_output=True, text=True, check=True
).stdout

files = []
total = 0
for line in listing.splitlines():
    # mode links owner group size mon day time-or-year path (9 whitespace-
    # separated fields; bsdtar -tvf always lists BOTH owner and group).
    parts = line.split(None, 8)
    if len(parts) < 9:
        continue
    mode, _links, _owner, _group, size, _mon, _day, _time, path = parts
    if mode.startswith("d") or path.startswith("."):
        continue
    size = int(size)
    files.append({"path": path, "size_bytes": size})
    total += size

with open(out_path, "w") as f:
    json.dump({"package_size_bytes": total, "files": files}, f, indent=2)
    f.write("\n")
PY

# --- metadata from .PKGINFO: the authoritative record of what THIS build
#     actually contains (pkgdesc/url/license/depends as makepkg resolved
#     them), plus a best-effort repo classification per dependency via the
#     container's own pacman sync db ---
bsdtar -xOf "$pkg_file" .PKGINFO > "$out_dir/.PKGINFO.raw"

python3 - "$out_dir/.PKGINFO.raw" "$out_dir/build_meta.json" <<'PY'
import json
import os
import subprocess
import sys

pkginfo_path, out_path = sys.argv[1], sys.argv[2]

fields = {"license": [], "depend": [], "optdepend": [], "makedepend": []}
description = None
url = None
packager = None

with open(pkginfo_path, encoding="utf-8") as fh:
    for line in fh:
        if " = " not in line:
            continue
        key, _, value = line.strip().partition(" = ")
        if key == "pkgdesc":
            description = value
        elif key == "url":
            url = value
        elif key == "packager":
            packager = value
        elif key in fields:
            fields[key].append(value)

TYPE_NAMES = {"depend": "depends", "optdepend": "optdepends", "makedepend": "makedepends"}


def classify(dep_spec: str, dep_type: str) -> dict:
    if dep_type == "optdepend" and ": " in dep_spec:
        dep_name, _, desc = dep_spec.partition(": ")
    else:
        dep_name, desc = dep_spec, None
    for sep in (">=", "<=", "=", ">", "<"):
        dep_name = dep_name.split(sep, 1)[0]

    repo = "aur"
    try:
        # Force C locale: pacman localizes field names based on the
        # container's LANG (e.g. it prints "Repository" only in English
        # locales), and we need to match that field name reliably.
        env = {**os.environ, "LC_ALL": "C"}
        out = subprocess.run(
            ["pacman", "-Si", dep_name], capture_output=True, text=True, timeout=10, env=env
        )
        for l in out.stdout.splitlines():
            if l.startswith("Repository"):
                repo = l.split(":", 1)[1].strip()
                break
    except (FileNotFoundError, subprocess.TimeoutExpired):
        repo = None

    entry = {"name": dep_name, "type": TYPE_NAMES[dep_type], "repo": repo}
    if desc:
        entry["description"] = desc
    return entry


dependencies = []
for dep_type in ("depend", "optdepend", "makedepend"):
    for dep in fields[dep_type]:
        dependencies.append(classify(dep, dep_type))

with open(out_path, "w") as f:
    json.dump(
        {
            "description": description,
            "url": url,
            "licenses": fields["license"],
            "packager": packager,
            "dependencies": dependencies,
        },
        f,
        indent=2,
    )
    f.write("\n")
PY

rm -f "$out_dir/.PKGINFO.raw"

echo "built $(basename "$pkg_file")"
