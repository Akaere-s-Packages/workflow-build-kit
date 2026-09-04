#!/usr/bin/env bash
set -euo pipefail
# Trace every command (with expanded arguments) to stderr by default. No
# secret ever flows through this script (GPG passphrase / R2 credentials
# only exist in publish/minio.sh), so there's nothing here that needs
# hiding — and full command-level tracing is exactly what was missing the
# times a build failed with nothing more than "Error: Process completed
# with exit code 1" and no visible reason why.
set -x

# archlinux backend: builds one AUR package with makepkg and emits, into
# $out_dir, the backends/<distro>/ build.sh contract's outputs (see
# backends/README.md):
#   <name>-<version>-x86_64.pkg.tar.zst   the built package
#   file_list.json                        {"package_size_bytes": N, "files": [...]}
#   build_meta.json                       {"description","url","licenses","packager","dependencies":[...]}
#
# Must run as root inside archlinux:base-devel (or equivalent) — it creates
# a throwaway non-root user internally because makepkg refuses to run as
# root.
#
# Usage: build.sh <name> <pkgbase> <out-dir> [aur_depends...]
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

# jq: not part of base-devel or the base archlinux image — needed here
# (unlike the rest of this script's coreutils/awk/bsdtar, all already
# present) because the file_list.json/build_meta.json generation below
# pipes through it. A real CI run caught this the first time: "jq:
# command not found" at the bsdtar|awk|jq step, since the old Python
# heredocs this replaced never needed it installed explicitly.
retry pacman -Sy --noconfirm --needed git jq

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
  # GIT_CURL_VERBOSE surfaces the actual HTTP/TLS-level reason for a clone
  # failure (DNS, timeout, TLS handshake, HTTP status) instead of just
  # git's one-line summary — the difference between this and a bare
  # "Error: Process completed with exit code 1" with nothing else to go on.
  retry su - builder -c "rm -rf '$dir' && GIT_CURL_VERBOSE=1 git clone --depth 1 'https://aur.archlinux.org/${base}.git' '$dir'"

  # A PKGBUILD that declares validpgpkeys expects those upstream release
  # keys to already be in the builder's keyring before makepkg verifies
  # the downloaded source's detached signature — but every build starts
  # from a completely fresh container, so that key is never there yet.
  # .SRCINFO lists the full fingerprint(s) makepkg actually needs (AUR
  # requires it to be kept in sync with the PKGBUILD).
  local skip_pgp_check=""
  local keys
  # `|| true` is load-bearing, not decoration: grep exits 1 when a package
  # (the common case — most PKGBUILDs don't declare validpgpkeys at all)
  # has no matches, and with `pipefail` + `set -e` that would otherwise
  # kill this whole script on a plain assignment, even though "no keys
  # needed" is the expected, successful outcome here, not an error.
  keys="$(grep -oP '(?<=validpgpkeys = )[0-9A-Fa-f]+' "$dir/.SRCINFO" 2>/dev/null | tr '\n' ' ' || true)"
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

  # Note: current makepkg (verified against 7.1.0) has no flag to restrict
  # which pkgname(s) of a split PKGBUILD actually get packaged — `-s`
  # always packages every pkgname the PKGBUILD declares in one run (e.g.
  # asusctl's PKGBUILD also produces rog-control-center every time it's
  # built, regardless of which one we're actually after). The compile
  # step is shared and only runs once either way, so this doesn't cost
  # extra build time — just a bit of extra disk for the sibling package's
  # file we don't keep. The match-exactly-one-file check below picks out
  # only the one this Registry entry actually tracks.
  # makepkg also does its own network I/O (downloading the actual
  # upstream sources, plus `-s` pulling any missing sync-repo deps via
  # pacman) — worth the same retry treatment as the clone above.
  retry su - builder -c "cd '$dir' && PACKAGER='$PACKAGER' makepkg -s --noconfirm --needed $skip_pgp_check"
}

# The file makepkg actually names one pkgname's output as — asked straight
# from makepkg itself (`--packagelist`, which sources the PKGBUILD exactly
# like a real build does — including running a pkgver() function — and
# just prints every output path, without building anything) instead of
# reconstructed by hand from .SRCINFO fields.
#
# Reconstructing it from .SRCINFO was this function's previous design, and
# it broke for real, twice:
#   - hardcoding "-x86_64.pkg.tar.zst" doesn't work for arch=(any) packages
#     (fonts, pure-data packages) or for epoch — makepkg's actual filename
#     includes the epoch (noto-fonts-sc-2:20210430-2-any.pkg.tar.zst)
#   - even after fixing that, linuxqq (epoch=5 at build time — the real
#     output was linuxqq-5:3.2.33_52892-1-x86_64.pkg.tar.zst) STILL didn't
#     match, because its committed .SRCINFO simply hadn't been regenerated
#     since the PKGBUILD picked up that epoch. Nothing on AUR enforces
#     PKGBUILD/.SRCINFO staying in sync — it's a maintainer convention, not
#     a guarantee — so re-deriving a filename from .SRCINFO can never be
#     fully reliable. Asking makepkg directly sidesteps the whole class of
#     "our copy of the metadata disagrees with what actually got built".
#
# --packagelist's own output isn't unambiguous by itself either — verified
# for real against a minimal two-pkgname split PKGBUILD, it printed THREE
# lines for two declared pkgnames, the third being the auto-generated
# debug package neither pkgname array nor .SRCINFO ever mentions. Filtering
# for exactly three trailing hyphen-free tokens ([epoch:]pkgver, pkgrel,
# arch) after "$pkgname-" rules that out the same way publish/minio.sh's
# retention matcher does: none of those three fields can contain a hyphen,
# so a sibling pkgname or a "-debug" output whose name happens to share
# this one as a prefix always leaves a leftover fourth token.
expected_package_file() {
  local base="$1" pkgname="$2"
  local dir="$work_dir/$base"
  local list f base_name
  list="$(su - builder -c "cd '$dir' && makepkg --packagelist")"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    base_name="$(basename "$f")"
    if [[ "$base_name" =~ ^${pkgname}-[^-]+-[^-]+-[^-]+\.pkg\.tar\.[a-z]+$ ]]; then
      echo "$f"
      return 0
    fi
  done <<< "$list"
  echo "$dir/$pkgname"  # deliberately nonexistent; caller checks -f and errors
}

# Chained AUR-only dependencies must be built and installed into the
# container first — makepkg --syncdeps only knows how to pull from pacman
# sync repos, not from AUR.
for dep in "${aur_depends[@]:-}"; do
  [[ -z "$dep" ]] && continue
  build_one "$dep"
  dep_pkg="$(expected_package_file "$dep" "$dep")"
  if [[ ! -f "$dep_pkg" ]]; then
    echo "expected built dependency package '$dep_pkg' not found" >&2
    ls -la "$work_dir/$dep" >&2 || true
    exit 1
  fi
  su - builder -c "sudo pacman -U --noconfirm '$dep_pkg'"
done

build_one "$pkgbase"

# This Registry entry only tracks (and keeps) the one pkgname named $name;
# the rest of makepkg's output for this build (sibling split packages,
# any auto-generated -debug package) gets discarded along with the whole
# container.
pkg_file="$(expected_package_file "$pkgbase" "$name")"
if [[ ! -f "$pkg_file" ]]; then
  echo "expected built package '$pkg_file' not found" >&2
  ls -la "$work_dir/$pkgbase" >&2 || true
  exit 1
fi
cp "$pkg_file" "$out_dir/"

# --- file list + total size, excluding directories and pacman's own
#     bookkeeping entries (.PKGINFO, .MTREE, .BUILDINFO, .INSTALL) ---
# awk extracts "size<TAB>path" for qualifying entries, then jq turns that
# into the final JSON — piped straight through (never held as a single
# jq command-line argument), since a package with several thousand files
# (visual-studio-code-bin, for real) would otherwise risk overflowing how
# much a subprocess can be handed as one argv entry.
bsdtar -tvf "$pkg_file" | awk '
  {
    # mode links owner group size mon day time-or-year path (9 whitespace-
    # separated fields; bsdtar -tvf always lists BOTH owner and group).
    # Capped at 9 fields, not free-split, so a path containing spaces
    # still comes through whole in $9-onward instead of getting chopped.
    if (NF < 9) next
    mode = $1
    size = $5
    path = $9
    for (i = 10; i <= NF; i++) path = path " " $i
    if (substr(mode, 1, 1) == "d") next
    if (substr(path, 1, 1) == ".") next
    print size "\t" path
  }
' | jq -R -s '
  split("\n") | map(select(length > 0)) | map(split("\t"))
  # bsdtar lists paths relative to the archive root (e.g.
  # "opt/1Password/1password", never a leading "/") — but these are real
  # installed absolute paths once pacman extracts the package onto a live
  # system, so store them that way everywhere this feeds into (website
  # file listings, PR-preview diff comments).
  | map({path: ("/" + .[1]), size_bytes: (.[0] | tonumber)})
  | . as $files
  | {package_size_bytes: ([$files[].size_bytes] | add // 0), files: $files}
' > "$out_dir/file_list.json"

# --- metadata from .PKGINFO: the authoritative record of what THIS build
#     actually contains (pkgdesc/url/license/depends as makepkg resolved
#     them), plus a best-effort repo classification per dependency via the
#     container's own pacman sync db ---
bsdtar -xOf "$pkg_file" .PKGINFO > "$out_dir/.PKGINFO.raw"

# classify_dep <dep-spec> <pkginfo-field-name> <output-type-name>: prints
# one dependency's classified JSON object. dep-spec is the raw PKGINFO
# value (e.g. "glibc>=2.31", or for optdepend "foo: needed for bar").
classify_dep() {
  local dep_spec="$1" dep_type="$2" type_name="$3"
  local dep_name="$dep_spec" desc=""

  if [[ "$dep_type" == "optdepend" && "$dep_spec" == *": "* ]]; then
    dep_name="${dep_spec%%: *}"
    desc="${dep_spec#*: }"
  fi
  local sep
  for sep in ">=" "<=" "=" ">" "<"; do
    dep_name="${dep_name%%"$sep"*}"
  done

  # Default "aur" (not found in any sync repo -> assumed to be another AUR
  # package); null only when pacman itself couldn't be asked at all (not
  # installed, or the lookup timed out) — a clean "not found in any repo"
  # answer from pacman still means "aur", not "unknown".
  local repo="aur"
  if ! command -v pacman >/dev/null 2>&1; then
    repo=""
  else
    local pacman_out pacman_status
    # Force C locale: pacman localizes field names based on the
    # container's LANG (e.g. it prints "Repository" only in English
    # locales), and we need to match that field name reliably.
    if pacman_out="$(LC_ALL=C timeout 10 pacman -Si "$dep_name" 2>/dev/null)"; then
      pacman_status=0
    else
      pacman_status=$?
    fi
    if [[ $pacman_status -eq 124 ]]; then
      repo=""
    else
      local repo_line
      repo_line="$(grep -m1 '^Repository' <<<"$pacman_out" || true)"
      [[ -n "$repo_line" ]] && repo="$(sed 's/^[^:]*:[[:space:]]*//' <<<"$repo_line")"
    fi
  fi

  jq -cn --arg name "$dep_name" --arg type "$type_name" --arg repo "$repo" --arg desc "$desc" '
    {name: $name, type: $type, repo: (if $repo == "" then null else $repo end)}
    + (if $desc != "" then {description: $desc} else {} end)
  '
}

description="" pkg_url="" packager=""
licenses=() depends=() optdepends=() makedepends=()
while IFS= read -r line; do
  [[ "$line" == *" = "* ]] || continue
  key="${line%% = *}"
  value="${line#* = }"
  case "$key" in
    pkgdesc) description="$value" ;;
    url) pkg_url="$value" ;;
    packager) packager="$value" ;;
    license) licenses+=("$value") ;;
    depend) depends+=("$value") ;;
    optdepend) optdepends+=("$value") ;;
    makedepend) makedepends+=("$value") ;;
  esac
done < "$out_dir/.PKGINFO.raw"

# Classified dependencies go to a temp NDJSON file (one object per line,
# not accumulated as command-line arguments) before the final jq assembly
# — same argv-safety reasoning as the file listing above; a package can
# have dozens of dependencies, cheap to get right regardless.
deps_ndjson="$(mktemp)"
for dep in "${depends[@]}"; do classify_dep "$dep" depend depends >> "$deps_ndjson"; done
for dep in "${optdepends[@]}"; do classify_dep "$dep" optdepend optdepends >> "$deps_ndjson"; done
for dep in "${makedepends[@]}"; do classify_dep "$dep" makedepend makedepends >> "$deps_ndjson"; done

licenses_json="$(printf '%s\n' "${licenses[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')"

jq -n --slurpfile deps "$deps_ndjson" --argjson licenses "$licenses_json" \
  --arg description "$description" --arg url "$pkg_url" --arg packager "$packager" '
  {
    description: (if $description == "" then null else $description end),
    url: (if $url == "" then null else $url end),
    licenses: $licenses,
    packager: (if $packager == "" then null else $packager end),
    dependencies: $deps
  }
' > "$out_dir/build_meta.json"
rm -f "$deps_ndjson" "$out_dir/.PKGINFO.raw"

echo "built $(basename "$pkg_file")"
