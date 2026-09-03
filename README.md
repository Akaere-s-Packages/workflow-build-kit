# workflow-build-kit

Reusable GitHub Actions workflows for [`Registry`](https://github.com/Akaere-s-Packages/Registry): build AUR packages, GPG-sign them, publish to a MinIO-backed pacman repo, sync [`WebSite-Kit`](https://github.com/Akaere-s-Packages/WebSite-Kit)'s display data, maintain Registry's own README, and check daily for upstream version updates.

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
| `MINIO_ENDPOINT` / `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` / `MINIO_BUCKET` | publishing to MinIO |
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

## `scripts/`

Organized by pipeline stage. Every script can run standalone outside a workflow (only depends on standard command-line tools: `bsdtar`/`pacman`/`mc`/`gpg`/`git`/`gh`/`jq`, no extra package dependencies):

| Path | Purpose |
|---|---|
| `registry/detect_changed_packages.sh` | Which `<distro>/<type>/<name>/<name>.toml` changed between two git refs |
| `registry/validate_schema.py` | Validate a toml against the package schema |
| `registry/update_readme.py` | Regenerate the package table in Registry/README.md |
| `aur/check_version.sh` | Look up one pkgbase's latest version on AUR |
| `aur/check_updates.py` | Find out-of-date autoupdate packages, group dependency-related ones, open PRs |
| `build/package.sh` | Build one package with makepkg inside `archlinux:base-devel`, extracting the file list and `.PKGINFO` metadata |
| `publish/minio.sh` | GPG-sign, `repo-add`, upload to MinIO, prune files beyond the newest 3 versions |
| `website/gen_data.py` | Merge Registry + this run's build output + AUR metadata into WebSite-Kit's JSON data |
| `preview/diff.py` | PR preview: file-level diff of a new build against what's published, as a Markdown comment |

## Known simplifications

- Everything assumes a single `x86_64` architecture.
- `build/package.sh` only keeps the one build product matching the Registry entry's `name`; if a PKGBUILD produces multiple packages, the rest are discarded (track them as separate Registry entries if needed).
- Internal checkouts of this repo are pinned to `@main`; switch to a tagged reference once this has run in production for a while.
