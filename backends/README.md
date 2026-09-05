# backends/

Every line of pacman/makepkg/repo-add/vercmp/AUR-RPC/PKGBUILD-specific
logic lives here, under `backends/<distro>/` — nowhere under `scripts/`
ever invokes a distro-specific tool directly. A Registry TOML's own
`distro` path segment (`archlinux/aur/<pkg>/...`) selects which
`backends/<distro>/` directory the generic orchestration scripts
(`scripts/registry/resolve_build_order.sh`, `scripts/update/check_updates.sh`,
`scripts/website/gen_data.sh`, and the `build-wave-*`/`build` matrix jobs
in the workflow YAML) dispatch to for that package.

Adding a second distro (AOSC, say) means adding a new `backends/aosc/`
directory that implements the same contract below — no changes to
anything under `scripts/`, `tools/`, or the reusable workflow YAML files
beyond a small per-distro lookup (build container image, see
`build-publish.yml`/`pr-preview.yml`'s `case "${{ matrix.distro }}" in
...` step) and setting up a matching bucket layout (see
[Docs/04](../../Docs/04-storage-minio-pacman-repo.md)).

## Currently implemented

- `archlinux/` — Arch Linux / AUR, built on `pacman`, `makepkg`,
  `repo-add`/`repo-remove`, `vercmp`, and the AUR RPC API.

## Contract

Every entry point below must exist and behave exactly this way for a
distro to be usable by the generic scripts. Nothing here is optional —
if a distro doesn't have an equivalent for one (a source index with no
public "package page" URL, say), the entry point must still exist and
produce the documented empty/null result rather than being omitted.

| Entry point | Contract |
|---|---|
| `build.sh <name> <pkgbase> <out-dir> [extra-deps...]` | Builds one package. Emits into `<out-dir>`: the built package file itself, `file_list.json` (`{"package_size_bytes": N, "files": [{"path","size_bytes"}, ...]}`, paths absolute-as-installed), and `build_meta.json` (`{"description","url","licenses":[...],"packager","dependencies":[{"name","type","repo"}, ...]}` — `type` is one of `depends`/`optdepends`/`makedepends`, `repo` is the classified source of that dependency or `null` if unknown). `extra-deps` are other same-distro packages (not otherwise available) that must be built and made available before `pkgbase` itself. Must run inside whatever build environment the distro needs (a container image, selected by the calling workflow YAML from `matrix.distro`). |
| `check-version.sh <pkgbase>` | Prints the latest upstream version string for `pkgbase`, exits 1 if unknown. Standalone manual/debug utility — not currently called by any generic script. |
| `fetch-info.sh` | stdin: JSON array of package **names** (not pkgbase — a split source package's several outputs can each have their own dependency list). stdout: `{"<name>": {"version","pkgbase","depends":[...],"description","url","license":[...],"maintainer","submitter","votes","popularity","first_submitted"}}` — `depends` is hard dependencies only (no soft/optional ones), names only (version constraints stripped), **not** restricted to Registry-tracked packages (callers intersect with their own tracked set). `pkgbase` is this name's real build-time base (usually equal to `name`, but not for a split package's non-base pkgname — e.g. Arch/AUR's `PackageBase`; a caller that needs to fetch/clone/build source for `name` must use this, never `name` itself, since a non-base pkgname's own upstream namespace is typically an empty placeholder). `first_submitted` is ISO8601 or `null`. A name the backend doesn't recognize is simply absent from the result. Must retry transient failures itself and degrade to `{}` (never a nonzero exit) on total failure — callers treat "no data" as "nothing to compare against", not a hard error. |
| `fetch-sources.sh <pkgbase>` | stdout: JSON array of `{"name", "url"?}` describing this pkgbase's declared upstream sources (omit `url` for a source with no meaningful one, e.g. a local patch file). Nonzero exit on failure — callers keep whatever sources data they already had rather than overwriting it with nothing. |
| `index-url.sh <pkgbase>` | Prints the URL of `pkgbase`'s listing on this distro's package index (used in autoPR bodies so a human reviewer can click through). No output (or a nonzero exit) if the distro has no such concept — callers fall back to plain text with no link. |
| `classify-dep.sh` | stdin: JSON array of dependency names. stdout: `{"<name>": "official"\|"aur", ...}` — every input name is always present (unlike `fetch-info.sh`, this never omits one). "official" means the distro's own package manager can install it directly (by real name **or** by a virtual/provided name — e.g. `cargo` is provided by `rust`, not its own package; checking only literal names misclassifies this whole common class and breaks `add_package.sh` on anything depending on one); "aur" means it isn't there and needs the chain-build treatment `aur_depends`/`build.sh`'s `extra-deps` already exist for. Used by `scripts/update/add_package.sh` to walk a requested package's dependency closure. |
| `repo_lib.sh` | Sourced (not run standalone) by `scripts/publish/minio.sh`/`publish_all.sh` — see below. |

### `repo_lib.sh` specifically

Publishing splits into two layers:

- `scripts/publish/repo_lib.sh` — generic S3 (`mc`) primitives every
  distro needs regardless of its index format: `retry`, `mc_alias_set`,
  `download_metadata_file`, `upload_package_file`, `upload_public_key`.
  Sourced once, unconditionally.
- `backends/<distro>/repo_lib.sh` — the distro's own repo-index format.
  Must define: `download_metadata_pair` (fetch the current index, valid
  "doesn't exist yet" case included), `sign_and_add` (GPG-sign one
  already-staged package file and fold it into the LOCAL index — no
  upload), `upload_repo` (upload the current local index to R2, once per
  batch, not once per package), `prune_old_versions` (delete a package's
  stale file versions beyond the retention count), `prune_removed_packages`
  (reconcile the index against the current Registry tree, dropping
  anything no longer tracked). Sourced *after* the generic
  `scripts/publish/repo_lib.sh`, since these functions call `retry`/
  `mc_alias_set`/etc. Callers set `repo_name`/`distro`/`alias_name`/
  `remote`/`db_file`/`files_file` as globals before calling anything here
  — see `minio.sh`/`publish_all.sh` for the exact derivation.

`publish_all.sh` processes a batch that may span multiple distros in one
run: it sources the distro-specific `repo_lib.sh` fresh at the top of
each iteration of its per-distro loop (not once at the top of the whole
script), so each iteration's `sign_and_add`/`upload_repo`/etc. resolve to
that iteration's own distro, not whichever happened to be sourced last.

**Known gap, deliberately out of scope for now**: the `publish` job's
own container is still hardcoded to `archlinux:base-devel` (`repo-add`/
`vercmp` need a real Arch environment) — a batch spanning two distros
with genuinely different index tooling (pacman vs. apt-family, say) would
need that job restructured to run each distro's `repo_lib.sh` work in its
own matching container. Not needed until a second distro's `repo_lib.sh`
actually exists.

## Not part of the contract

`tools/depgraph` (the shared dependency-graph engine) is distro-agnostic
by design — it operates on a generic name/edge-list, built by the
*generic* scripts from `fetch-info.sh`'s normalized `depends` field. No
backend ever calls it directly, and no backend needs to know it exists.
