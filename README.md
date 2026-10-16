# Snapcell (하루칸)

A phone app for people who keep an analog, calendar-based diary with small day cells (default 30 mm × 20 mm). Pick photos for diary dates, and Snapcell generates print-ready grid sheets (default 4 in × 5.5 in photo paper) you can print, cut out, and paste into your diary.

## Features

- Assign multiple candidate photos to any date, with a short comment each
- Mark a favorite per date
- Generate sheets for any date range
- Configurable paper size and diary cell size
- Android first, iPhone later

## Status

Scaffolded. Dev environment and workspace are set up; no features yet.

## Docs

- [Business requirements](docs/requirements.md)

## Development setup (macOS)

Versions are pinned: Flutter 3.47.7 via [FVM](https://fvm.app) (`.fvmrc`), JDK 17.

```sh
brew install fvm android-commandlinetools
brew install --cask temurin@17

# Android SDK (accept licenses when prompted)
sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0" \
  "emulator" "system-images;android-36;google_apis;arm64-v8a"

fvm install            # reads .fvmrc
fvm flutter config --android-sdk "$ANDROID_HOME" --jdk-dir "$JAVA_HOME"
fvm flutter doctor     # Android toolchain must be green; Xcode is not needed yet
```

Shell environment (`~/.zshrc`):

```sh
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
```

Emulator: `avdmanager create avd -n snapcell_pixel -d pixel_8 -k "system-images;android-36;google_apis;arm64-v8a"`, then `emulator -avd snapcell_pixel`.

### Common commands

```sh
fvm flutter pub get                       # from the repo root (pub workspace)
(cd packages/sheet_engine && fvm dart test)
(cd app && fvm flutter test)
(cd app && fvm flutter run)               # with the emulator running
fvm flutter analyze && fvm dart format --output=none --set-exit-if-changed .
```

Generated code (`*.g.dart`, drift) is not committed. Once drift is added, run
`fvm dart run build_runner build --delete-conflicting-outputs` after cloning
(see ADR-0007).

## Releasing

Releases are signed arm64 APKs that GitHub Actions builds when a `v*` tag is pushed (ADR-0010, ADR-0011). They are not published to a store: download the APK from the repository's **Releases** page. The repository is public, so anyone can.

One-time setup:

1. Create the release keystore outside the repository:
   ```sh
   keytool -genkeypair -v -keystore ~/snapcell-release.jks -storetype JKS \
     -keyalg RSA -keysize 2048 -validity 10000 -alias snapcell
   ```
2. Back up the keystore file and its passwords somewhere outside GitHub. If they are lost nobody can update the app in place, and users lose their data by reinstalling.
3. Create an environment named `release` (Settings > Environments) and restrict it to the tag pattern `v*` (Deployment branches and tags > Selected branches and tags > add a tag rule).
4. Add these secrets to the `release` environment:
   - `ANDROID_KEYSTORE_BASE64`: output of `base64 < ~/snapcell-release.jks | tr -d '\n'`
   - `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`
   - `ANDROID_KEY_ALIAS`: `snapcell`

To release: `git tag v0.1.0 && git push origin v0.1.0`. Pull requests that change code run `check` and build a debug APK automatically.

Installing: allow installs from unknown sources for the app you download with (Android or Play Protect may warn about an unknown source). Later releases update in place because they use the same key. A debug build from a laptop uses a different key, so uninstall it before installing a release.
