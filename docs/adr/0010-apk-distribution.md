# ADR-0010: APK distribution — signed release APK on `v*` tags, via GitLab Release

- Status: Accepted (2026-10-16; no pipeline has run and the keystore does not exist yet, see Open items)
- Date: 2026-10-16
- Amends: ADR-0007 (which left release builds and signing out of scope)
- Related: ADR-0001, ADR-0003, ADR-0007
- Amended by: [ADR-0011](0011-github-hosting-and-ci.md) (GitHub Release instead of GitLab; environment secrets; `github.run_number`; the repository and APK are public, so the members-only assumption no longer holds. The GitLab-specific text below is historical)

## Context

Snapcell is not published to an app store. A few people, all added as members of the GitLab project, download an APK from the repository and install it on their phones (sideloading).

Constraints that shape the pipeline:

- **Updates need a stable signing key.** Android installs an APK over an existing install only if both are signed with the same key. A debug build is signed with an auto-generated debug key, and each machine or CI runner generates its own. Debug APKs from successive pipelines therefore cannot update each other.
- **An uninstall deletes the user's data.** The app is local-only with no backend (ADR-0001). Forcing an uninstall to change keys loses every date, photo reference and comment.
- **There is no store safety net.** With Play App Signing, Google holds the app signing key and can recover an upload key. Here, losing the keystore means nobody can ever update the app in place.
- **The scaffold signs release builds with the debug key** (`app/android/app/build.gradle.kts`, the `release` build type), as the Flutter template does. That must change before anything is distributed.
- **GitLab artifacts are not a release store.** The GitLab docs say job artifacts are for output that belongs to one pipeline, that artifacts kept by "keep artifacts from most recent successful jobs" ignore `expire_in`, and that the "latest on branch" URL points to different files after each pipeline. For a versioned release they recommend the package registry ([Job artifacts](https://docs.gitlab.com/ci/jobs/job_artifacts/), checked 2026-10-16).
- The project is a personal gitlab.com project, so the company proxy variables do not apply (ADR-0007).

## Decision

### Trigger

Pushing a Git tag `v<MAJOR>.<MINOR>.<PATCH>` (for example `v0.1.0`) starts a release. `v*` is configured as a **protected tag** so only maintainers can create it, and so protected CI/CD variables are available to the pipeline. A tag that does not match the pattern fails the release job early.

### Signing

- One **release keystore**, created once on the author's machine with `keytool` (RSA 2048, long validity), never committed.
- GitLab CI/CD variables, all **protected** (available on protected tags only):
  - `ANDROID_KEYSTORE_BASE64`: the keystore as one line of base64, masked and hidden. A File-type variable holds text and a keystore is binary, so the file is stored encoded and decoded by the job (about 2.7 kB encoded).
  - `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`: masked and hidden
  - `ANDROID_KEY_ALIAS`
- The release job decodes the keystore and writes `app/android/key.properties` from these variables, following the structure in the Flutter Android deployment docs (checked 2026-10-16). `build.gradle.kts` reads that file for the `release` signing config.
- `key.properties`, `*.jks` and `*.keystore` are added to `.gitignore`.
- **Local `flutter run --release`** keeps working: if `key.properties` is absent the release build type falls back to the debug key. The CI release job fails if `key.properties` is missing, so a debug-signed APK cannot be published by accident.
- **Backup:** the keystore file and its passwords are stored outside GitLab (for example in a password manager) as soon as they are created. This is a prerequisite for the first tag, not a later task.

### Versioning

- Version name is the tag without the `v`. Build number (`versionCode`) is `CI_PIPELINE_IID`, which increases with every pipeline in the project, so every release has a higher code than the previous one.
- Passed on the command line: `flutter build apk --release --build-name=<name> --build-number=$CI_PIPELINE_IID`. The `version:` in `app/pubspec.yaml` stays as the development default and is not the release source of truth.

### ABI

Build for **arm64 only** (`--target-platform android-arm64`). This produces one smaller APK and covers current phones and the Apple Silicon emulator. A phone that is 32-bit-only cannot install it. Revisit if a user hits that.

### Pipelines

| Pipeline | Jobs |
|---|---|
| Merge request (code changes only) | As in ADR-0007: `check`, and a manual `build-apk` (debug, a build check; artifact kept 1 week) |
| Tag `v*` | The same check and test jobs, then `build-release`, `publish`, `release` |

- `build-release` runs with the Flutter version pinned in `.fvmrc` (ADR-0007), writes `key.properties`, builds the signed APK, and keeps it as a job artifact for 1 week. This artifact only passes the file to the next job.
- `publish` uploads the APK to the project's **generic package registry** as `snapcell/<tag>/snapcell-<tag>.apk` (for example `snapcell/v0.1.0/snapcell-v0.1.0.apk`), authenticating with `CI_JOB_TOKEN`.
- `release` then creates a **GitLab Release** for the tag with the `release:` keyword, with an asset link to that package file. It must run in the `registry.gitlab.com/gitlab-org/cli` image, which the GitLab release examples use. Upload is a separate job because that image is not known to include `curl`, and `release:` cannot expand variables set inside `script`, so the tag is used directly as the package version.
- Users download the APK from the project's **Releases** page. Package files do not expire; a maintainer deletes old ones.

### Installing (to go in the README)

Enable "install unknown apps" for the app used to open the download. Android or Play Protect may warn about an app from an unknown source. Updates install in place because every release uses the same key. A release APK cannot be installed over a debug build of the app: the keys differ, so the debug build must be uninstalled first.

## Options considered

| Question | Chosen | Alternative | Why not |
|---|---|---|---|
| Build type | Signed release | Debug APK | Per-runner debug key breaks updates; larger and slower |
| Trigger | `v*` tag | Every merge to `main` | Not deliberate; version numbers would come from pipeline counters |
| Storage | Package registry + Release | Job artifacts only | Expire or move, per GitLab docs; no stable per-version URL |
| | | Firebase App Distribution, other services | Outside GitLab; adds an account and a dependency for a few users |
| Signing key | One keystore in protected CI variables | Keystore committed to the repo | Secret in git history |
| | | Sign on the author's laptop and upload by hand | Not reproducible; defeats the pipeline |
| ABI | arm64 only | Universal APK | Larger; the extra ABIs serve no known user |

## Consequences

- The author creates and backs up the keystore before the first tag. Losing it ends in-place updates for everyone.
- Releases are deliberate: nothing is distributed until a tag is pushed.
- Members who download need a project role that can see Releases and package files. To verify before the first tag (see Open items).
- Release builds are not exercised by the debug-only checks. Android's code shrinking (R8) can remove classes that debug builds keep, which matters once plugins from ADR-0004, ADR-0005 and ADR-0006 are added. The first release APK must be installed and smoke-tested on a device or emulator before it is shared.
- A signed APK from a different keystore is a different app to Android. Rotating the key is a breaking change for installed users.

## Open items

- Confirm GitLab accepts the base64 keystore as a masked and hidden variable (its character and length rules) when the variable is created.
- Confirm which GitLab role a member needs to view Releases and download package files in a private project on gitlab.com, and set the members' roles accordingly.
- ~~Confirm that `--build-number` and `--build-name` override `pubspec.yaml`.~~ Verified locally with Flutter 3.47.7 on 2026-10-16: versionCode and versionName in the built APK came from the flags.
- Confirm that arm64-only is acceptable for every intended user's phone.
- Confirm how R8 shrinking is configured for release builds in the scaffold, and run the first release build on a device.
  - 2026-10-16: the signed release APK from `v0.0.2` (scaffold only, no plugins) installed and launched on a physical phone. This shows signing and packaging work. It does not exercise R8 against plugin code, so repeat the check when the first plugin from ADR-0004, ADR-0005 or ADR-0006 is added (`adb logcat -s AndroidRuntime` after launch).
- Add the install notes above to the README when the pipeline exists.
