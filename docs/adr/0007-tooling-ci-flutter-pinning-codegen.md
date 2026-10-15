# ADR-0007: Tooling — GitLab CI, Flutter version pinning, generated code

- Status: Proposed (draft; no pipeline has run, and the Flutter version is not chosen yet)
- Date: 2026-10-15
- Related: ADR-0001, ADR-0002, ADR-0003

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
- **CI:** the job image tag is the same exact version, for example `ghcr.io/cirruslabs/flutter:<version>`. The tag is never `stable` or `latest`.
- **`pubspec.yaml`:** keep `environment:` constraints (`sdk:`, `flutter:`) as a lower bound that matches the pin, so a too-old SDK fails fast.
- **Upgrades** are their own commit that changes `.fvmrc`, the CI image tag, and the constraints together, with the tests green.
- The version itself is chosen when the project is scaffolded (the latest stable at that time), not in this ADR.

Two places (`.fvmrc`, CI image tag) must stay in sync. A CI job that compares them is not worth building yet; the upgrade rule above covers it.

### Generated code: not committed

`build_runner` output (`*.g.dart`, drift included) is **gitignored** and generated in CI and on each developer machine with `dart run build_runner build --delete-conflicting-outputs`.

- Generated files add large, noisy diffs and can merge-conflict with no human meaning.
- CI regenerates them anyway, so a stale committed file could pass review and still differ from what CI builds.
- The cost is a required step after clone and after schema or annotation changes. This is documented in the README.

Exceptions that **are** committed:

- **drift schema snapshots** (`drift_schemas/`, from `dart run drift_dev schema dump`). They are inputs for migration tests (ADR-0002), not build output.
- **`gen_l10n` output**, only if the Flutter version pinned above writes it into `lib/` rather than a synthetic package. To be verified against the Flutter docs when the project is scaffolded; the default is to follow what the tool does and gitignore it if it can be regenerated.

If `build_runner` time becomes a burden, the option to revisit is committing the output with a CI freshness check (`build_runner build`, then `git diff --exit-code`). It is not chosen now because it adds a check for a problem that does not exist yet.

### CI: GitLab CI

One `.gitlab-ci.yml` with these jobs, running on GitLab.com shared runners using the pinned Flutter image:

| Stage | Job | Command |
|---|---|---|
| `check` | `analyze` | `dart run build_runner build`, then `flutter analyze` and `dart format --output=none --set-exit-if-changed .` |
| `test` | `test-engine` | `dart test` in `packages/sheet_engine` (no code generation needed) |
| `test` | `test-app` | `dart run build_runner build`, then `flutter test` in `app` |
| `build` | `build-apk` | `flutter build apk --debug`, artifact kept for a short time |

- Cache the pub cache (`PUB_CACHE`), keyed on `pubspec.lock`. `pubspec.lock` is committed for `app` (an application, not a library).
- Pipelines run on merge requests and on `main`.
- A release build, signing, and store upload are out of scope. They need their own ADR when a release is planned.
- The company proxy variables (`http_proxy`, `https_proxy`, `no_proxy`) are **not** added: they apply to the `code.siemens.com` runners only, and this is a personal gitlab.com project.
- On-device checks (ADR-0004, ADR-0005, ADR-0006) cannot run in this pipeline and stay manual. CI covers `dart test` and `flutter test` only.

## Options considered

| Question | Chosen | Alternative | Why not |
|---|---|---|---|
| Version pin | `.fvmrc` + CI image tag | `pubspec.yaml` constraint only | A range does not pin the SDK; CI and laptop can differ |
| | | Image tag only | Local builds can drift from CI |
| | | `asdf` / `mise` | Equivalent, but FVM is Flutter-specific and has IDE support |
| Generated code | Gitignored | Committed + freshness check | Extra check and noisy diffs for no current benefit |
| CI runner | GitLab.com shared, prebuilt Flutter image | Self-installed SDK per job | Slower, and the install is another thing to pin |

## Consequences

- A fresh clone does not compile until `build_runner` has run. The README must say so.
- Upgrading Flutter is a deliberate, reviewed change.
- The pipeline gives red/green feedback for the pure-Dart engine and the Flutter app, but not for anything needing a device or emulator.

## Open items

- Choose the Flutter version when scaffolding, and verify the image tag exists for it.
- Confirm where `gen_l10n` writes its output in that version, and set the gitignore rule accordingly.
- Confirm the pub workspace syntax (ADR-0003) works with the cache and `dart test` paths used above.
- Confirm GitLab.com shared runner time is enough for `flutter build apk`; if not, drop `build-apk` from merge requests and run it on `main` only.
