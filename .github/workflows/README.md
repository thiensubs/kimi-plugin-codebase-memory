# GitHub Actions

Two workflows, one shared build contract. Both compile every C hook in `c/` on
four platforms and run the test suite; only the tag build publishes.

| Workflow | Trigger | Publishes |
| --- | --- | --- |
| `ci.yml` | every branch push, every pull request, manual dispatch | nothing — artifacts only |
| `release.yml` | push of a `v*` tag | one zip, four tarballs, `SHA256SUMS` |

Tag pushes are excluded from `ci.yml` on purpose (`branches` alone ignores tags),
so a release does not run the matrix twice.

## Matrix

| platform | runner | architecture |
| --- | --- | --- |
| `linux-x86_64` | `ubuntu-24.04` | x86_64 |
| `linux-arm64` | `ubuntu-24.04-arm` | arm64 |
| `darwin-x86_64` | `macos-15-intel` | x86_64 |
| `darwin-arm64` | `macos-15` | arm64 |

The platform strings are the directory names under `bin/prebuilt/`, which is what
`bin/run` resolves at runtime (`bin/prebuilt/<os>-<arch>/<tool>`).

`macos-13` and `macos-14` are **not** used: `macos-13` has been retired and
`macos-14` is deprecated ([runner image list](https://github.com/actions/runner-images#available-images)).
If a newer image becomes the right pin, change the two `runs-on` values in both
workflows and nothing else.

## Scripts

`.github/scripts/build-hooks.sh` — builds every `c/*.c` twice: `bin/<name>` (the
host binary the tests execute) and `bin/prebuilt/<os>-<arch>/<name>` (the release
artifact). Flags are `-O2 -std=c11 -Wall -Wextra -Werror`, so a warning fails the
build. After compiling it checks each output with `file(1)` against the platform
tag it was written to, so a mislabelled directory cannot survive.

`.github/scripts/run-tests.sh` — runs `tests/run-tests.sh` when it exists
(that file is the canonical runner and must itself run every `tests/test-*.sh`);
otherwise it runs each `tests/test-*.sh` directly. A checkout with no tests exits
0 with a notice, so the pipeline is green while the suite is still landing. The
job fails if any test file exits non-zero. `KIMI_CODE_HOME` is redirected to the
runner's temp directory so the hooks can never write into a real home.

## Release assets

`release.yml` runs the same matrix, then a `package` job that checks out the tag,
downloads the four `prebuilt-*` artifacts, and:

1. verifies every artifact exists and that `file(1)` reports the architecture its
   directory name promises (a darwin binary in `linux-*` fails the release);
2. builds the plugin tree from `git archive HEAD` — tracked files only, no `.git`,
   no `.tmp`, no `.github` — and overlays the four fresh `bin/prebuilt/` trees;
3. fails if the manifest version does not equal the tag (`v0.2.0` needs
   `"version": "0.2.0"`);
4. writes `codebase-memory-plugin.zip` with `kimi.plugin.json` at the archive
   root, every binary for every platform inside, and mode `0755` on the binaries
   (the Kimi installer only restores the modes the zip records, and uploaded
   artifacts lose the executable bit);
5. writes one `codebase-memory-<version>-<platform>.tar.gz` per platform,
   pruned to that platform's prebuilt directory.

Stable marketplace URL:

```
https://github.com/thiensubs/kimi-plugin-codebase-memory/releases/latest/download/codebase-memory-plugin.zip
```

## Cutting a release

1. Bump `version` in `kimi.plugin.json` (and `marketplace.json` if it carries a
   version) and commit it.
2. Commit every file the plugin ships: the archive is built with
   `git archive HEAD`, so untracked files do not reach the zip.
3. `git tag v<version> && git push origin v<version>`.

The workflow needs `contents: write` on `GITHUB_TOKEN` (already declared on the
`package` job) and no repository secrets.

## Not covered here

- Linux binaries link against the runner's glibc (Ubuntu 24.04), so they may not
  start on an older distribution. Pin `ubuntu-22.04` for `linux-x86_64` if that
  matters; `bin/run` still falls back to compiling from source.
- The committed `bin/prebuilt/*` trees are refreshed by `scripts/build-all.sh`
  for darwin and by this pipeline for release archives; nothing here commits
  them back.
