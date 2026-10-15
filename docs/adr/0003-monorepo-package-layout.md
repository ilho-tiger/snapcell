# ADR-0003: Monorepo package layout — `sheet_engine` + `app`

- Status: Accepted
- Date: 2026-10-15

## Context

The app is built with Flutter (ADR-0001). Its most logic-heavy part is generating sheets: packing units onto paper, cell geometry, mm-to-px conversion, crop math, label formatting, and date-range handling (FR-2.x to FR-6.x). This logic is pure computation and has no need for Flutter.

The author is new to Flutter, so the structure should be easy to reason about, and the project follows TDD, so the logic should be testable quickly without an emulator.

A Flutter code base is organised into *packages* (a folder with a `pubspec.yaml`, comparable to a `.csproj` in C# or a `package.json` in TS). A monorepo holds several packages in one git repository.

## Options considered

### A. Two packages: `sheet_engine` (pure Dart) + `app` (Flutter)
- The compiler enforces the boundary: `sheet_engine` depends on the Dart SDK only, so it cannot import `dart:ui` or Flutter.
- Tests run with `dart test` (fast, no Flutter test harness).
- Costs: a second `pubspec.yaml`, workspace or path-dependency setup, and a conversion step at the boundary (for example `sheet_engine` `Rect` to `ui.Rect`).

### B. One package, with the engine in `app/lib/core/`
- Simpler setup, no conversion step.
- The boundary is convention only. A lint rule can forbid Flutter imports in that folder, but the structure does not stop them.
- Tests would run under `flutter test`.

## Decision

Use **two packages in one repository**, with a pub workspace or path dependency from `app` to `sheet_engine`:

```
snapcell/
├── pubspec.yaml            # workspace root, lists both packages
├── packages/
│   └── sheet_engine/       # pure Dart
│       ├── pubspec.yaml    # depends on the Dart SDK only
│       ├── lib/
│       └── test/
└── app/                    # Flutter app
    ├── pubspec.yaml        # depends on sheet_engine, Flutter, Riverpod, drift, ...
    ├── lib/
    ├── test/
    └── android/
```

The name `sheet_engine` was chosen over `layout_core` because "layout" collides with Flutter's widget-layout vocabulary and "core" is vague. The package turns configuration, a date range and a photo count into a sheet plan.

### Responsibilities

| `sheet_engine` (pure Dart) | `app` (Flutter) |
|---|---|
| Config model: paper, cell, inset, spacing, margins, DPI | UI screens and widgets |
| mm to px math (FR-6.3) | Riverpod providers (ADR-0002) |
| Packing: units per sheet, row and column placement, sheet count | drift database and repositories (ADR-0002) |
| Cell geometry: photo rectangle, label cell, cut-guide lines | `CustomPainter` drawing sheets, shared by preview and export |
| Crop-rectangle math (cover, center crop) | Photo picker, gallery save, isolates, JPEG encode |
| Date-range and label-formatting logic | i18n (ARB files) |

The engine returns plain data (for example, "sheet 1, unit 7 at x, y, w, h in px, label rect ..."). It never draws. The `app` painter reads that data and draws it.

### Validation

`sheet_engine` validates the config before planning (FR-6.9, requirements §4.1). Validation returns a list of typed `ConfigError` values, so the UI can show every problem at once. The engine never throws for invalid user input and never auto-corrects it. Limits (DPI 150–600, paper side 50–300 mm, at most 25 MP per sheet, cell must fit at least once) live as constants in the engine and are covered by its tests. `plan` is only callable with a validated config.

## Consequences

- `sheet_engine` uses its own minimal geometry types (`Rect`, `Size`, `Point`). `app` converts them to `dart:ui` types at the boundary.
- Engine tests are written first (TDD) and run with `dart test`, which is fast and needs no emulator.
- The engine's rules and tests serve as a reference if a framework fallback (ADR-0001) were ever needed, although the code itself would need porting.
- A second `pubspec.yaml` and workspace setup are needed. The exact pub workspace syntax must be confirmed against the Dart docs before writing the files.
- Merging `sheet_engine` into `app/lib/core/` later is a mechanical change if the overhead proves not worth it.

## Rejected alternative

Option B (one package). Simpler, but the Flutter-free boundary would depend on discipline and lint rules rather than on the dependency graph.

## Related

- ADR-0001: Application framework (Flutter)
- ADR-0002: State management and persistence (Riverpod + drift)
