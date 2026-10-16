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
