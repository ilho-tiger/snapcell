# ADR-0011: Hosting and CI — move from GitLab.com to GitHub (public), GitHub Actions

- Status: Accepted (2026-10-16; verified end to end with the `v0.0.2` dry run, see Open items)
- Date: 2026-10-16
- Amends: [ADR-0007](0007-tooling-ci-flutter-pinning-codegen.md) (CI section and compute budget), [ADR-0010](0010-apk-distribution.md) (secrets, versioning, storage, who can download)
- Related: ADR-0003

## Context

The repository was on the GitLab.com free tier, which allows 400 shared-runner minutes per month (ADR-0007). A pipeline of four jobs cost 14.2 minutes, and even the trimmed `check` job costs about 2.1, so every design choice in the pipeline was driven by that quota. GitHub does not limit minutes on standard hosted runners for public repositories.

## Decision

- The repository is `github.com/ilho-tiger/snapcell`, **public**. The GitLab project is archived (read-only) and kept for history.
- CI is one GitHub Actions workflow, `.github/workflows/ci.yml`, with the same shape as before:
  - `check`: on every pull request and on `v*` tags. Same commands as ADR-0007. There is no path filter: `check` is a required status check on `main`, and a filtered workflow never reports on docs-only changes, which would leave the PR blocked.
  - `build-apk` (debug): on pull requests. It is now automatic, not manual, because there is no quota to protect. Artifact kept 7 days.
  - `release`: on `v*` tags, after `check`. Builds the signed arm64 APK and creates a GitHub Release with the APK attached.
- Flutter is installed with `subosito/flutter-action`, reading the version from `.fvmrc`, with its SDK and pub caches. This replaces the `git clone` of the SDK and the cirruslabs image. The JDK is set up with `actions/setup-java` (Temurin 17). All actions are pinned to commit SHAs, because the release job holds the signing key.
- Signing secrets (`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`) are secrets of a `release` **environment** restricted to `v*` tags. This replaces "protected variables on protected tags". Everything in ADR-0010 about the keystore itself (one key, never committed, backed up before the first tag) is unchanged.
- `versionCode` is `github.run_number` instead of `CI_PIPELINE_IID`. Both increase per workflow run, so releases still get ever-higher codes. No release was built on GitLab, so there is no earlier code to stay above.
- The generic package registry and the separate `publish` job are gone: the release asset is the APK's permanent location.

## Consequences

- **The signed APK and the source are public.** Anyone can download and install the app; ADR-0010's "a few project members" is no longer a restriction. Nothing secret is in git history (checked 2026-10-16 for private keys, tokens, keystores and `key.properties` before the first push). The keystore stays out of the repository.
- The compute-budget rules in ADR-0007 (single `check` job, manual APK build, no pipeline on docs-only changes beyond the path filter, `interruptible`) no longer need to hold. The path filter on pull requests was removed (see above); a docs-only PR now costs about 2 minutes of free runner time.
- Pull requests from forks get no secrets. The release job only runs on tags, in the `release` environment.
- Issues #1 to #5 were recreated on GitHub with the same numbers. Merge request references in earlier text (for example "MR !5") refer to GitLab.

## Options considered

| Question | Chosen | Alternative | Why not |
|---|---|---|---|
| Host | GitHub public | GitHub private (2,000 min/month on Free) | Still a quota; public is unlimited for standard runners |
| | | GitLab with a self-registered runner | Keeps the host, but needs the author's machine on for every build |
| Flutter in CI | `subosito/flutter-action` | Prebuilt image or `git clone` | The image lags Flutter releases; the clone has no caching built in |
| Release storage | GitHub Release asset | Package registry or artifacts | Artifacts expire; a release gives a stable per-tag URL |

## Open items

- ~~Run the workflow on the first pull request and fix what fails.~~ `check` and the debug `build-apk` passed on PR #6 (2026-10-16). The `release` job is skipped on pull requests by design.
- ~~Create the `release` environment, restrict it to `v*` tags, and add the four secrets before the first tag.~~ Done 2026-10-16. The existing keystore was reused, so no APK signed with a different key exists.
- ~~Exercise the release job.~~ Tag `v0.0.2` ran `check` and `release` successfully on 2026-10-16. The APK is signed with the author's release certificate (not the debug key), `dev.isong.snapcell`, versionName 0.0.2, versionCode 2 (`github.run_number`), arm64 only. The `v0.0.2` release is kept; it is a pre-release version.
- Re-measure `check` duration on GitHub runners (1m45s on PR #6, with a cold cache) and update the figure in ADR-0007 if it matters.
- Smoke test of the release APK: installed and launched on a physical phone on 2026-10-16, scaffold only. See ADR-0010 for what is still open.
