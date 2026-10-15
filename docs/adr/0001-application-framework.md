# ADR-0001: Application framework — Flutter

- Status: Accepted, pending #1 (the JPEG export pipeline and DPI approach are unverified; do not build on them as settled)
- Date: 2026-10-15
- Resolves: OQ-1 in `docs/requirements.md`

## Context

Snapcell is a phone app, Android first (US-2, §1.3). iPhone is a "maybe someday", not a planned deliverable. There is no backend: the app is local-only and single-user.

Requirements that constrain the choice:

- Pick photos from the phone and save generated JPEGs to the gallery (FR-6.7), which depends on platform APIs.
- Decode phone photos, crop to cover, downscale, composite a 1200 × 1650 px sheet, draw labels and cut guides, and encode JPEG with the DPI declared in metadata (FR-6.1 to FR-6.5). This is memory-sensitive and must stay off the UI thread.
- The preview (FR-2.8) must not drift from the final output, so both should share one render path.
- All user-facing strings are translatable, including the app name (FR-7.2, FR-7.3).

The author is fluent in C#, TypeScript/JavaScript and Go, and has no Flutter or Kotlin experience. The author wants to use this project to learn Flutter.

## Options considered

| | Flutter | Capacitor + React + TS | Expo / React Native + TS | Kotlin + Compose | .NET MAUI | PWA |
|---|---|---|---|---|---|---|
| Language fit for author | New (Dart), close to C# / TS | TS | TS | New | C# | TS |
| Render path | `dart:ui` canvas, shared by preview and export | Canvas 2D | react-native-skia offscreen | Native bitmap | SkiaSharp | Canvas 2D |
| Gallery save, photo picker | Packages (to be verified) | Plugins (to be verified) | Packages | Best, native APIs | Packages | Weak |
| iPhone later | Same code base | Same code base | Same code base | Rewrite | Same code base, tooling is shaky | Browser only |
| Main risk | No JPEG encoder in `dart:ui`; Android scoped-storage packages | Plugin quality for picker and gallery save | Offscreen JPEG encode is less proven | iOS port is a rewrite | Android stability and ecosystem | Gallery saving and photo access |

## Decision

Use **Flutter** with Dart.

- Learning Flutter is an explicit goal of the author. This outweighs the lower ramp-up cost of the TypeScript options (Capacitor, Expo), which were the technically comparable alternatives.
- Dart is close enough to C# and TypeScript that the language cost is small.
- `dart:ui` gives a single render path: the preview is a `CustomPainter`, and the export runs the same painter into a `PictureRecorder` and calls `Picture.toImage`.
- One code base keeps an iPhone port open without committing to it.

Rejected:

- **PWA**: weak gallery saving and photo access, and no reliable way to keep photo references (OQ-2).
- **Kotlin + Compose**: best native control, but the iPhone port would be a rewrite and the author has no experience with it.
- **.NET MAUI**: matches the author's C#, but Android stability and ecosystem maturity are concerns.
- **Capacitor / Expo**: viable, and the preferred choice on pure effort. Kept as fallbacks if a blocking Flutter limitation appears. The layout engine is kept framework-free (see below) so a fallback would not discard it.

## Consequences

- `dart:ui` cannot encode JPEG (it exposes raw RGBA and PNG). The RGBA bytes are encoded in a background `Isolate`, for example with the pure-Dart `image` package, with a native-backed encoder as the fallback.
- DPI metadata (FR-6.4) is applied by patching the JFIF density bytes after encoding, unless the chosen encoder already supports it. To be checked in a spike before relying on either answer.
- The packing and layout engine lives in a pure-Dart package, `packages/sheet_engine`, with no Flutter imports. It is tested with `dart test` and is independent of the UI framework.
- Localization uses Flutter's built-in `gen_l10n` with ARB files. The app name is an ARB string (FR-7.3).
- The photo picker and gallery-save packages are chosen in [ADR-0005](0005-photo-picker-and-gallery-save.md), which stays Proposed until the on-device checks listed there pass.
- State and persistence choices are recorded in ADR-0002.

## Related

- ADR-0002: State management and persistence (Riverpod + drift)
