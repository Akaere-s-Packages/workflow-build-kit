# workflow-build-kit

Reusable GitHub Actions workflows for [`Registry`](https://github.com/Akaere-s-Packages/Registry): build AUR packages, GPG-sign them, publish to a R2-backed pacman repo, sync [`WebSite-Kit`](https://github.com/Akaere-s-Packages/WebSite-Kit)'s display data, maintain Registry's own README, and check daily for upstream version updates.

## Reusable workflows

### `build-publish.yml` — on merge to main: build, publish, sync data

```yaml
# Registry/.github/workflows/build.yml
on:
  push:
    branches: [main]
    paths: ["*/*/*/*.toml"]
jobs:
  build-publish:
    uses: Akaere-s-Packages/workflow-build-kit/.github/workflows/build-publish.yml@main
    with:
      base-sha: ${{ github.event.before }}
      head-sha: ${{ github.event.after }}
    secrets: inherit
```

Secrets required (set on the Registry repo):

| Secret | Used for |
|---|---|
| `R2_ENDPOINT` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `R2_BUCKET` | publishing to R2 |
| `GPG_PRIVATE_KEY` (base64-encoded armor export) / `GPG_PASSPHRASE` | signing packages |
| `WEBSITE_KIT_PUSH_TOKEN` | a token with push access to the WebSite-Kit repo |

### `pr-preview.yml` — on an open PR: build only, comment the file diff

```yaml
# Registry/.github/workflows/pr-preview.yml
on:
  pull_request:
    paths: ["*/*/*/*.toml"]
permissions:
  pull-requests: write
  contents: read
jobs:
  preview:
    uses: Akaere-s-Packages/workflow-build-kit/.github/workflows/pr-preview.yml@main
    with:
      base-sha: ${{ github.event.pull_request.base.sha }}
      head-sha: ${{ github.event.pull_request.head.sha }}
      pr-number: ${{ github.event.pull_request.number }}
```

Takes no secrets at all — the comparison baseline is WebSite-Kit's public JSON on GitHub Pages, fetched over plain HTTP. Safe even if Registry ever accepts PRs from forks.

### `version-check.yml` — daily: check AUR for updates, open PRs

```yaml
# Registry/.github/workflows/version-check.yml
on:
  schedule:
    - cron: "0 2 * * *"
  workflow_dispatch: {}
jobs:
  version-check:
    uses: Akaere-s-Packages/workflow-build-kit/.github/workflows/version-check.yml@main
    secrets: inherit
```

Requires `LILITHYA_PUSH_TOKEN`: a token with permission to branch, push, and open PRs on the Registry repo (commits as `Lilithya <me@lilithya.su>`).

Packages that hard-depend on each other (via AUR's `Depends`/`MakeDepends`) and both have updates available are bundled into a single PR — one commit per package, dependencies committed before dependents, each commit message following the [AOSC packaging commit convention](https://wiki.aosc.io/developer/packaging/package-styling-manual/) (`$pkgname: update to $pkgver`). Unrelated updates each get their own PR.

If a group's branch already has an open PR, this doesn't open a second one: it force-pushes the branch in place with the current target versions and updates the PR's title/body, or leaves it untouched if it's already at the exact versions being targeted.

Every PR this opens/updates gets GitHub's native auto-merge enabled (rebase strategy) using the same `LILITHYA_PUSH_TOKEN`, so it merges itself once its required status checks (pr-preview's build) pass — no extra secret, and `pr-preview.yml` stays exactly as secret-free as before. This needs two one-time repo settings that no workflow can set: **Allow auto-merge** and **Allow rebase merging** under Settings → General, plus pr-preview's build check added as a required status check on `main`'s branch protection.
## `scripts/`

Organized by pipeline stage. Every script can run standalone outside a workflow (only depends on standard command-line tools: `bsdtar`/`pacman`/`mc`/`gpg`/`git`/`gh`/`jq`, no extra package dependencies):

| Path | Purpose |
|---|---|
| `registry/detect_changed_packages.sh` | Which `<distro>/<type>/<name>/<name>.toml` changed between two git refs |
| `registry/validate_schema.py` | Validate a toml against the package schema |
| `registry/update_readme.py` | Regenerate the package table in Registry/README.md |
| `registry/aur_graph.py` | Shared dependency-graph helpers (batched AUR RPC fetch, hard-Depends/MakeDepends graph, connected components, topological/layered ordering) — imported by both `aur/check_updates.py` and `registry/resolve_build_order.py`, not run standalone |
| `registry/resolve_build_order.py` | Expand a changed-package set to everything hard-dependent on it, laid out in up to N dependency-ordered build layers |
| `aur/check_version.sh` | Look up one pkgbase's latest version on AUR |
| `aur/check_updates.py` | Find out-of-date autoupdate packages, group dependency-related ones, open/force-update PRs, enable auto-merge on them |
| `build/package.sh` | Build one package with makepkg inside `archlinux:base-devel`, extracting the file list and `.PKGINFO` metadata |
| `publish/minio.sh` | GPG-sign, `repo-add`, upload to R2, prune files beyond the newest 3 versions |
| `publish/publish_all.sh` | Orchestrates the whole `publish` job: install `mc`, import the GPG key once, loop over built packages calling `minio.sh`, assemble `built_packages.json`. Must run inside `archlinux:base-devel` (`repo-add`/`vercmp` ship with `pacman` itself — nothing to install on a bare Ubuntu runner) |
| `website/gen_data.py` | Merge Registry + this run's build output + AUR metadata into WebSite-Kit's JSON data |
| `preview/diff.py` | PR preview: file-level diff of a new build against what's published, as a Markdown comment |

### Build ordering

`build-publish.yml` doesn't just build the packages that literally changed — `resolve_build_order.py` expands that set to every Registry package hard-dependent on one of them (e.g. bumping `asusctl` also rebuilds `rog-control-center`, since it `Depends` on asusctl), then lays the whole set out into up to 5 layers ("waves"): layer 0 has no unbuilt dependency within the set, layer 1 depends only on layer 0, etc. Only hard `Depends`/`MakeDepends` count — `OptDepends` is a soft suggestion, not something worth rebuilding over.

Each wave is its own job (`build-wave-0` through `build-wave-4`), matrixed in parallel internally, `needs:`-chained so each wave only starts once the previous one has fully finished (regardless of whether the previous wave itself was skipped for being empty — see the `always()` guards in the job `if:` conditions). 5 layers is a deliberate, documented cap (raised from an initial 3, since GitHub Actions' job graph is static and can't grow a new wave job at runtime no matter how deep a real dependency chain gets): `resolve_build_order.py` errors loudly if the real dependency graph among tracked packages ever needs more than that, rather than silently building out of order.

`pr-preview.yml` does the same expansion but flattens all layers into one parallel matrix — build order doesn't matter there (nothing depends on `makepkg` running in a particular sequence for a preview build), only "build everything related" does.

### Manual full rebuild

`build-publish.yml` also takes an optional `rebuild-all: true` input, which skips the git-diff-based change detection entirely (`registry/detect_changed_packages.sh --all`) and treats every package in the registry as "changed" — `resolve_build_order.py` then just lays the whole registry out into build layers instead of an expanded subset. Wire it up as its own manually-triggered workflow:

```yaml
# Registry/.github/workflows/rebuild-all.yml
on:
  workflow_dispatch: {}
permissions:
  contents: write
  issues: write
  actions: read
jobs:
  build-publish:
    uses: Akaere-s-Packages/workflow-build-kit/.github/workflows/build-publish.yml@main
    with:
      rebuild-all: true
    secrets: inherit
```

Use this after a fix to `build/package.sh` (or similar) that should apply retroactively, after rotating the GPG signing key, or to recover from a bad publish — not part of the normal per-change flow.

## Known simplifications

- Everything assumes a single `x86_64` architecture.
- `build/package.sh` only keeps the one build product matching the Registry entry's `name`; if a PKGBUILD produces multiple packages, the rest are discarded (track them as separate Registry entries if needed).
- Internal checkouts of this repo are pinned to `@main`; switch to a tagged reference once this has run in production for a while.
