# ADR-0002: State management and persistence — Riverpod + drift

- Status: Accepted
- Date: 2026-10-15

## Context

Snapcell is a local-only, single-user Flutter app (Android first). There is no backend. State is mostly a derived chain: configuration → date range → favorites → packed layout → rendered sheets. Persisted data is small and relational: dates, photos (each belonging to exactly one date), a favorite flag, comments, and one global config.

The author is new to Flutter and Dart but fluent in C#, TypeScript and Go. The project follows TDD, so the data and state layers should be testable without an emulator.

Package status checked on pub.dev on 2026-10-15; all four candidates are actively maintained:

| Package | Latest | Published |
|---|---|---|
| flutter_riverpod | 3.4.3 | 2026-09-03 |
| provider | 6.1.5+1 | 2025-08-19 |
| drift | 2.35.2 | 2026-10-07 |
| sqflite | 2.4.4+2 | 2026-10-13 |

## Options considered

### State management

| | Riverpod 3 | provider 6 |
|---|---|---|
| Async data | `AsyncValue` built in (loading / error / data) | Hand-wired via `FutureProvider`, `StreamProvider` or `ChangeNotifier` |
| Dependencies between state | Providers read other providers; derived state recomputes automatically | Needs `ProxyProvider` or manual wiring |
| Access without `BuildContext` | Yes; tests override providers without a widget tree | No; tied to the widget tree |
| Testing | `ProviderContainer` + overrides; pure Dart tests | Usually needs widget-test scaffolding |
| Learning curve | Steeper (`ref.watch` vs `read`, optional codegen) | Gentle |
| Boilerplate | Moderate | Low at first, grows with dependencies |

### Persistence

| | drift | sqflite |
|---|---|---|
| Query style | Typed Dart tables and queries, checked at compile time | Raw SQL strings and `Map<String, Object?>` |
| Codegen | Required (`drift_dev`, `build_runner`) | None |
| Reactivity | Queries can be watched as `Stream`s | Manual re-query after writes |
| Migrations | Schema-versioned, with generated verification and test helpers | Hand-written `onUpgrade` SQL |
| One-to-many (date → photos, favorite) | Typed relations and joins | Hand-written join SQL and manual mapping |
| Testing | In-memory DB, runs on desktop with `dart test` | Platform channel; needs `sqflite_common_ffi` for tests |
| Weight | Heavier (codegen, build time) | Light |

## Decision

Use **Riverpod** for state management and **drift** (SQLite) for persistence.

- Riverpod fits the derived chain (config → range → layout → render), where automatic recomputation replaces hand-rolled wiring that `provider` would need.
- drift's typed schema, migration tooling and in-memory tests allow the repository layer to be tested under `dart test` without an emulator, in line with the TDD default.
- drift exposes watchable queries as `Stream`s, which Riverpod consumes directly.

To limit the learning surface while new to Flutter, start with the **plain Riverpod API without `riverpod_generator`**. Revisit codegen later if the boilerplate becomes a burden.

## Consequences

- Two more concepts to learn at once (Riverpod and drift) alongside Flutter itself.
- A `build_runner` step is required for drift's generated code.
- Repository interfaces sit between drift and the rest of the app, so the layer can be tested and replaced independently.
- The pure-Dart layout engine (`sheet_engine`) does not depend on either package.

## Open items

- `sqlite3_flutter_libs` is marked end-of-life (`0.6.0+eol`) on pub.dev. Older drift setup guides depend on it. Confirm drift's current Flutter setup against its official docs before adding dependencies.
- The image picker and gallery-save packages, and their Android scoped-storage verification, are covered in [ADR-0005](0005-photo-picker-and-gallery-save.md).

## Rejected alternative

`provider` + `sqflite`: faster to a first working screen and lighter, but async derived state gets awkward around the render and generation flow, and schema migrations are hand-written. Judged a worse fit for this app even though its schema is small.

## Related

- ADR-0001: Application framework (Flutter)
