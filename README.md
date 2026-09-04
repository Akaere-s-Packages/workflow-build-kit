# workflow-build-kit

Reusable GitHub Actions workflows for [`Registry`](https://github.com/Akaere-s-Packages/Registry): build packages, GPG-sign them, publish to a R2-backed repo, generate a GitHub Artifact Attestation for each published file, sync [`WebSite-Kit`](https://github.com/Akaere-s-Packages/WebSite-Kit)'s display data, maintain Registry's own README, and check daily for upstream version updates.

All logic is bash + jq (+ one small C program, see `tools/depgraph/` below) — no Python anywhere in this repo. Every line specific to a single distro's packaging tools (currently just Arch/AUR: `pacman`/`makepkg`/`repo-add`/`vercmp`/the AUR RPC API) lives behind a `backends/<distro>/` seam with a fixed contract (see [`backends/README.md`](backends/README.md)); the scripts under `scripts/` and the workflow YAML never invoke a distro-specific tool directly, and dispatch to the right backend using the Registry TOML's own `distro` field. That seam exists so a second distro (AOSC) can be added later as a new `backends/aosc/` directory, without touching the orchestration logic.

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

The calling workflow also needs `id-token: write` and `attestations: write` permissions (no secret — a caller-granted permission, same as `contents`/`issues`/`actions` already are) for the `publish` job's `actions/attest-build-provenance` step, which gives every successfully-published package file a GitHub-signed build provenance attestation, verifiable with `gh attestation verify <file> --repo Akaere-s-Packages/Registry`. Public repos only, unless the org is on GitHub Enterprise Cloud.

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

This script never merges anything itself — see `merge-queue.yml` below for that.

### `merge-queue.yml` — after pr-preview/build-and-publish: merge one ready autoPR

```yaml
# Registry/.github/workflows/merge-queue.yml
on:
  workflow_run:
    workflows: ["pr-preview", "build-and-publish"]
    types: [completed]
  workflow_dispatch: {}
jobs:
  drain-queue:
    uses: Akaere-s-Packages/workflow-build-kit/.github/workflows/merge-queue.yml@main
    secrets: inherit
```

Merges at most one ready `bump/*` autoPR (see `check_updates.sh` above) per invocation, using the same `LILITHYA_PUSH_TOKEN` — no extra secret. "Ready" means both: (1) its own pr-preview build has passed and it's cleanly mergeable, and (2) this repo's Actions are completely idle (nothing else queued or in progress) — so merges never overlap, and a merge's `build-and-publish` run always finishes before the next `bump/*` PR merges. Deletes the head branch as part of the merge. Re-triggers itself on every pr-preview/build-and-publish completion, so the queue drains one PR at a time without a human or a blind poll involved. Needs one one-time repo setting no workflow can set: **Allow rebase merging** under Settings → General (branch protection requiring pr-preview's build check is recommended as defense in depth, but `merge_queue.sh` already verifies checks itself before merging).

### `add-package.yml` — manual: quick-add one upstream package (+ its dependency closure)

```yaml
# Registry/.github/workflows/add-package.yml
on:
  workflow_dispatch:
    inputs:
      package-name:
        description: Upstream package name to introduce (e.g. an AUR pkgname)
        required: true
        type: string
jobs:
  add-package:
    uses: Akaere-s-Packages/workflow-build-kit/.github/workflows/add-package.yml@main
    with:
      package-name: ${{ inputs.package-name }}
    secrets: inherit
```

Type in one package name, get back a PR. Resolves the full hard-dependency closure that isn't already installable through the distro's own package manager (via `backends/<distro>/fetch-info.sh` + the new `classify-dep.sh`, see `backends/README.md`) and generates a Registry TOML entry for every package in that closure that isn't already tracked — not just the one requested, so a dependency chain (however deep) comes in as one bundled PR instead of needing N manual runs. Ordering and commit style match `check_updates.sh`: dependencies committed before dependents, `$pkgname: add $pkgver` per commit, one PR on branch `add/<name1>+<name2>+...`.

Deliberately conservative compared to `check_updates.sh`'s daily job: if the target branch already has an open PR, this leaves it alone rather than force-pushing over it (an autoPR is expected to be rewritten daily; a manually-triggered add-PR might be mid-review). If the requested package (and everything under it) is already tracked, it's a no-op. If a dependency turns out to be resolvable through *neither* the package manager nor upstream (see `scripts/update/add_package.sh`'s real example below), the run fails loudly rather than silently generating a broken entry.

Caught a genuine upstream bug the day this was built: asked to add a package whose PKGBUILD `depends` on a since-renamed official package name, the only way to "resolve" it looked like chain-building an orphaned AUR package by the old name — which itself depended on something that exists in neither the official repos nor AUR at all. The run correctly refused to proceed instead of producing a Registry entry that would fail at build time anyway; the actual fix was a one-line PKGBUILD update upstream, not anything in the Registry.

## `scripts/`

Distro-agnostic orchestration, organized by pipeline stage — nothing here ever invokes a distro-specific tool directly (see `backends/` below). Every script can run standalone outside a workflow (only depends on standard command-line tools: `bash`/`jq`/`curl`/`git`/`gh`/`gpg`, no extra package dependencies beyond those):

| Path | Purpose |
|---|---|
| `lib/toml.sh` | Sourced, not run standalone: reads the flat `[PACKAGES]` table Registry TOML files always use into JSON (`toml_to_json`/`toml_get`/`toml_get_list`) |
| `lib/run.sh` | Sourced, not run standalone: `run`/`retry_run` subprocess helpers used by `update/*.sh` — capture a command's stdout/stderr for parsing while still printing both, so a failed `git`/`gh` call shows what it actually said instead of a bare error |
| `registry/detect_changed_packages.sh` | Which `<distro>/<type>/<name>/<name>.toml` changed between two git refs |
| `registry/validate_schema.sh` | Validate a toml against the package schema |
| `registry/update_readme.sh` | Regenerate the package table in Registry/README.md |
| `registry/load_registry.sh` | Load every Registry package entry as JSON — used by `resolve_build_order.sh`, `update/check_updates.sh`, and `website/gen_data.sh` |
| `registry/resolve_build_order.sh` | Expand a changed-package set to everything hard-dependent on it, laid out in up to N dependency-ordered build layers (via `tools/depgraph`) |
| `update/check_updates.sh` | Find out-of-date autoupdate packages (via each package's own `backends/<distro>/fetch-info.sh`), group dependency-related ones (via `tools/depgraph`), open/force-update `bump/*` PRs (never merges them — see `merge_queue.sh`) |
| `update/merge_queue.sh` | Merge at most one ready `bump/*` autoPR per run — its own checks green and this repo's Actions idle — so autoPR merges never overlap. Run by `merge-queue.yml`. Not distro-specific at all (pure GitHub PR-queue mechanics) |
| `update/add_package.sh` | Quick-add: given one upstream package name, resolves its full dependency closure that isn't already installable through the package manager (via `fetch-info.sh` + `classify-dep.sh`), generates a Registry TOML entry for every new package in the closure, and opens one bundled PR. Run by `add-package.yml` (manual, one name typed in via `workflow_dispatch`) |
| `build/stage_artifact.sh` | Stage/restore build artifact filenames so they're safe for `actions/upload-artifact` (Windows-forbidden characters percent-encoded) |
| `publish/repo_lib.sh` | Generic S3 (`mc`) upload primitives (sourced, not run standalone) — download/upload metadata objects, upload one package's file. The repo-INDEX-format-specific half (sign+index one package, prune) is `backends/<distro>/repo_lib.sh`, sourced separately — see `backends/README.md` |
| `publish/minio.sh` | Publishes exactly one package end-to-end: downloads the index, signs + indexes this one package, uploads the index back, prunes. `KEEP_VERSIONS` default 1 |
| `publish/publish_all.sh` | Orchestrates the whole `publish` job for a batch of packages (possibly spanning multiple distros): install `mc`, import the GPG key once, then for every built package sign + index it into ONE local index per distro and upload that index exactly once per distro (not once per package — the previous per-package-calls-minio.sh design re-fetched and re-uploaded the same index objects on every single successful package, which dominated a multi-package publish job's wall-clock time for no reason), stage a copy of each published file under `attest-artifacts/` for the workflow's own `actions/attest-build-provenance` step (see below), assemble `built_packages.json` (now including each published file's `filename`/`sha256`) |
| `website/gen_data.sh` | Merge Registry + this run's build output + upstream metadata (via `backends/<distro>/fetch-info.sh`/`fetch-sources.sh`) into WebSite-Kit's JSON data |
| `preview/diff.sh` | PR preview: file-level diff of a new build against what's published, as a Markdown comment (file table capped to stay under GitHub's 65536-char comment body limit) |

## `backends/` and `tools/depgraph/`

`backends/<distro>/` holds everything specific to one distro's packaging tools — see [`backends/README.md`](backends/README.md) for the full contract every backend must implement, and what's currently in `backends/archlinux/`.

`tools/depgraph/` is a small C11 program (built via `make -C tools/depgraph`, no dependencies beyond libc) doing the one piece of graph logic (connected components, cycle-tolerant topological order, layered/wave ordering) that's genuinely awkward to get right in bash — real recursion/backtracking over sets, which bash has no real call stack for. It's distro-agnostic itself: `resolve_build_order.sh` and `check_updates.sh` build its input edge-list from `fetch-info.sh`'s normalized `depends` field, so depgraph never needs to know AUR or pacman exist.

### Build ordering

`build-publish.yml` doesn't just build the packages that literally changed — `resolve_build_order.sh` expands that set to every Registry package hard-dependent on one of them (e.g. bumping `asusctl` also rebuilds `rog-control-center`, since it depends on asusctl), then lays the whole set out into up to 5 layers ("waves") via `tools/depgraph`: layer 0 has no unbuilt dependency within the set, layer 1 depends only on layer 0, etc. Only hard dependencies count — a soft/optional dependency is not something worth rebuilding over.

Each wave is its own job (`build-wave-0` through `build-wave-4`), matrixed in parallel internally, `needs:`-chained so each wave only starts once the previous one has fully finished (regardless of whether the previous wave itself was skipped for being empty — see the `always()` guards in the job `if:` conditions). 5 layers is a deliberate, documented cap (raised from an initial 3, since GitHub Actions' job graph is static and can't grow a new wave job at runtime no matter how deep a real dependency chain gets): `resolve_build_order.sh` errors loudly if the real dependency graph among tracked packages ever needs more than that, rather than silently building out of order.

`pr-preview.yml` does the same expansion but flattens all layers into one parallel matrix — build order doesn't matter there (nothing depends on `makepkg` running in a particular sequence for a preview build), only "build everything related" does.

### Manual full rebuild

`build-publish.yml` also takes an optional `rebuild-all: true` input, which skips the git-diff-based change detection entirely (`registry/detect_changed_packages.sh --all`) and treats every package in the registry as "changed" — `resolve_build_order.sh` then just lays the whole registry out into build layers instead of an expanded subset. Wire it up as its own manually-triggered workflow:

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

Use this after a fix to `backends/archlinux/build.sh` (or similar) that should apply retroactively, after rotating the GPG signing key, or to recover from a bad publish — not part of the normal per-change flow.

### Retry failed packages

`build-publish.yml` also accepts `retry-failed: true`, used by
`Registry/.github/workflows/retry-failed.yml`. It finds open issues carrying the
`build-failure` label, extracts their machine-generated `[build-failure] <name>`
titles, and selects current Registry manifests with those names. The selected
packages and their hard dependents are rebuilt in normal dependency order.
Malformed issue titles and titles for deleted manifests are ignored. A successful
retry publishes the package and closes its failure issue; an unsuccessful retry
leaves the issue open for another manual retry.

## Known simplifications

- Everything assumes a single `x86_64` architecture.
- `backends/archlinux/build.sh` only keeps the one build product matching the Registry entry's `name`; if a PKGBUILD produces multiple packages, the rest are discarded (track them as separate Registry entries if needed).
- Internal checkouts of this repo are pinned to `@main`; switch to a tagged reference once this has run in production for a while.
- The `publish` job's own container is hardcoded to `archlinux:base-devel` — a batch spanning two distros with genuinely different index tooling would need that job restructured to run each distro's `backends/<distro>/repo_lib.sh` work in its own matching container. See `backends/README.md`'s "known gap" note; not addressed until a second distro's `repo_lib.sh` actually exists.
