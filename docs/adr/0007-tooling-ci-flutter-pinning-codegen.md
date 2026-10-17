# ADR-0007: Tooling — CI, Flutter version pinning, generated code

- Status: Accepted (2026-10-17; Flutter pinned to 3.47.7 via `.fvmrc` and used by CI since PR #6. The CI section is superseded by ADR-0011; pinning and the generated-code policy stand)
- Date: 2026-10-15
- Related: ADR-0001, ADR-0002, ADR-0003
- Amended by: [ADR-0011](0011-github-hosting-and-ci.md) (hosting and CI moved from GitLab to GitHub Actions; the "CI: GitLab CI" section, its compute budget and the CI-runner row below are historical)

## Context

Three tooling questions have no recorded answer, and each affects every later commit:

1. **CI.** The repository is hosted on gitlab.com (`origin` is `git@gitlab.com:ilho-song/snapcell.git`). There is no pipeline yet. The code base has two packages (ADR-0003): `sheet_engine` is pure Dart and tested with `dart test`; `app` is Flutter and tested with `flutter test`.
2. **Flutter version.** Flutter and Dart ship together, and `pubspec.yaml` SDK constraints are ranges. Without a pin, a laptop and the CI runner can build with different SDKs, and a Flutter upgrade can break the build with no change in the repository.
3. **Generated code.** ADR-0002 adopts drift, which requires `drift_dev` and `build_runner` (`*.g.dart`). It also chooses plain Riverpod without `riverpod_generator`, so drift is the only `build_runner` consumer for now. Localization uses `gen_l10n` (ADR-0001), which is a separate Flutter tool, not `build_runner`.

The author works alone, is new to Flutter, and has no release process yet (no signing, no store). TDD is the default, so CI must run the tests on every push.

## Decision

### Flutter version pinning

Pin one exact Flutter version, and use it everywhere.

- **Source of truth:** `.fvmrc` at the repository root ([FVM](https://fvm.app)). Developers run `fvm flutter ...`.
- **CI:** each job installs Flutter at the version read from `.fvmrc` (a shallow `git clone --branch <version>` of `flutter/flutter`, cached by the hash of `.fvmrc`). The job image only supplies the JDK and Android SDK. A prebuilt Flutter image is not used: `ghcr.io/cirruslabs/flutter` has no tag newer than `3.44.0`, built 2026-05-20 (checked 2026-10-16), so the pinned `3.47.7` has no image.
- **`pubspec.yaml`:** keep `environment:` constraints (`sdk:`, `flutter:`) as a lower bound that matches the pin, so a too-old SDK fails fast.
- **Upgrades** are their own commit that changes `.fvmrc` and the constraints together, with the tests green.
- The version itself is chosen when the project is scaffolded (the latest stable at that time), not in this ADR.

`.fvmrc` is the only place the version is pinned, so CI and local builds cannot drift apart.

### Generated code: not committed

`build_runner` output (`*.g.dart`, drift included) is **gitignored** and generated in CI and on each developer machine with `dart run build_runner build --delete-conflicting-outputs`.

- Generated files add large, noisy diffs and can merge-conflict with no human meaning.
- CI regenerates them anyway, so a stale committed file could pass review and still differ from what CI builds.
- The cost is a required step after clone and after schema or annotation changes. This is documented in the README.

The generator dependencies are `drift_dev` and `build_runner` (dev dependencies). The runtime side is `drift_flutter`; `sqlite3_flutter_libs` is end-of-life and is not used (ADR-0002).

Exceptions that **are** committed:

- **drift schema snapshots** (`drift_schemas/`, from `dart run drift_dev schema dump`). They are inputs for migration tests (ADR-0002), not build output.
- **`gen_l10n` output**, only if the Flutter version pinned above writes it into `lib/` rather than a synthetic package. To be verified against the Flutter docs when the project is scaffolded; the default is to follow what the tool does and gitignore it if it can be regenerated.

If `build_runner` time becomes a burden, the option to revisit is committing the output with a CI freshness check (`build_runner build`, then `git diff --exit-code`). It is not chosen now because it adds a check for a problem that does not exist yet.

### CI: GitLab CI

One `.gitlab-ci.yml` with these jobs, running on GitLab.com shared runners, on an image with the JDK and Android SDK (`ghcr.io/cirruslabs/flutter:3.44.0`, used for those two only) and Flutter installed from `.fvmrc`:

| Stage | Job | Command |
|---|---|---|
| `check` | `check` | `flutter analyze` and `dart analyze`, `dart format --output=none --set-exit-if-changed app packages`, `dart test` in `packages/sheet_engine`, `flutter test` in `app`. Once drift is added, `dart run build_runner build` runs first. |
| `build` | `build-apk` | `flutter build apk --debug`. Manual on merge requests (not run automatically); artifact kept 1 week. |

Release jobs on tags are in [ADR-0010](0010-apk-distribution.md).

**Compute budget.** The project is on the GitLab free tier: 400 shared-runner minutes per month, billed as the sum of job durations. The first pipeline (analyze, test-engine, test-app and an automatic debug build) cost 14.2 minutes, about 28 runs a month, and about 3.5 of those minutes were pulling the same Flutter image once per job. The pipeline is therefore kept lean:

- One `check` job, so the image is pulled and Flutter set up once.
- The debug APK build is manual on merge requests. The signed release build on tags is the real APK build.
- Pipelines run only on merge requests that change `app/`, `packages/`, the pubspecs, `.fvmrc` or `.gitlab-ci.yml`, and on tags. Documentation-only changes cost nothing, and `main` is not rebuilt after a merge.
- `check` and `build-apk` are `interruptible`, so a newer push cancels an older run.

- Cache the pub cache (`PUB_CACHE`), keyed on `pubspec.lock`. `pubspec.lock` is committed for `app` (an application, not a library).
- Pipelines do not run on `main`: the merge request pipeline already ran the same code.
- Store upload is out of scope. Signed release APKs, signing, and distribution on `v*` tags are decided in [ADR-0010](0010-apk-distribution.md).
- The company proxy variables (`http_proxy`, `https_proxy`, `no_proxy`) are **not** added: they apply to the `code.siemens.com` runners only, and this is a personal gitlab.com project.
- On-device checks (ADR-0004, ADR-0005, ADR-0006) cannot run in this pipeline and stay manual. CI covers `dart test` and `flutter test` only.

## Options considered

| Question | Chosen | Alternative | Why not |
|---|---|---|---|
| Version pin | `.fvmrc`, installed in CI | `pubspec.yaml` constraint only | A range does not pin the SDK; CI and laptop can differ |
| | | Image tag only | Local builds can drift from CI, and the image can lag Flutter (it has, since May) |
| | | `asdf` / `mise` | Equivalent, but FVM is Flutter-specific and has IDE support |
| Generated code | Gitignored | Committed + freshness check | Extra check and noisy diffs for no current benefit |
| CI runner | GitLab.com shared, SDK installed from `.fvmrc` | Prebuilt Flutter image | No image exists for the pinned version; its publisher lags, so every upgrade would wait on it |

## Consequences

- A fresh clone does not compile until `build_runner` has run. The README must say so.
- Upgrading Flutter is a deliberate, reviewed change.
- The pipeline gives red/green feedback for the pure-Dart engine and the Flutter app, but not for anything needing a device or emulator.

## Open items

- ~~Flutter version chosen at scaffolding.~~ 3.47.7 (2026-10-16), in `.fvmrc` and read by CI.
- Confirm where `gen_l10n` writes its output in that version, and set the gitignore rule accordingly.
- ~~Confirm the pub workspace syntax (ADR-0003) works with the cache and `dart test` paths used above.~~ `check` passes on every PR with the workspace layout (ADR-0011).
- Measured 2026-10-16: the `check` job took 126 s (about 2.1 billed minutes) with warm Flutter and pub caches. Quota no longer applies (ADR-0011); re-measure only if `build_runner` makes `check` slow.
- ~~An alternative if the quota still binds: register the author's machine as a project runner.~~ Moot after the move to GitHub (ADR-0011).
- Still open: where `gen_l10n` writes its output, and the matching gitignore rule. Decide when localization is added. The drift `build_runner` step is verified only in spike 003, not yet in `app`.
