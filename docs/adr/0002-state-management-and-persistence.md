# ADR-0002: State management and persistence — Riverpod + drift

- Status: Accepted
- Date: 2026-10-15

## Context

Snapcell is a local-only, single-user Flutter app (Android first). There is no backend. Part of the state is a cheap derived chain (configuration → date range → favorites → packed layout). Generation itself is not derived: it is a user-driven flow (favorite choice, empty-date confirmation, preview, save) around an expensive render. Persisted data is small and relational: dates, photos (each belonging to exactly one date), a favorite flag, comments, and one global config.

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

- Riverpod fits the cheap derived state (config → range → layout), where automatic recomputation replaces hand-rolled wiring that `provider` would need. Rendering is excluded from that chain; see [Generation flow](#generation-flow).
- drift's typed schema, migration tooling and in-memory tests allow the repository layer to be tested under `dart test` without an emulator, in line with the TDD default.
- drift exposes watchable queries as `Stream`s, which Riverpod consumes directly.

To limit the learning surface while new to Flutter, start with the **plain Riverpod API without `riverpod_generator`**. Revisit codegen later if the boilerplate becomes a burden.

## Generation flow

Generation is an explicit, cancellable state machine owned by a `GenerationController` (a Riverpod `Notifier`), not a chain of auto-recomputing providers. Rendering never reruns because an upstream value changed.

`Rendering` runs in a foreground service and is resumable; see [ADR-0006](0006-background-generation.md), which supersedes the rendered-sheet lifecycle and the `sheets/` sweep below.

States: `Configuring → ResolvingFavorites → ConfirmingEmpties → Rendering → Previewing → Saving → Done | Failed`. Cancel is allowed from any state before `Saving` completes. Transitions are plain Dart and are tested with `ProviderContainer`, without a widget tree.

- **Favorites (FR-2.2):** the choice is written to the database immediately and stays if the user cancels later. It is a preference about a photo, not part of the output. The UI says so when asking.
- **Rendered sheets:** `Rendering` writes each sheet to a temp file in the app cache directory. Memory is not used, because a decoded A4 sheet at print DPI is tens of MB and several sheets risk an Android out-of-memory kill. The controller holds the file list. Temp files live in a dedicated subdirectory (`sheets/`), are deleted on cancel and on done, and orphans are swept by the startup reconciliation step below.
- **Save:** sheets are saved sequentially, with per-sheet status `saved(uri)` or `failed(error)`. Retry re-attempts only failed sheets from the temp files and does not re-render. Sheets already saved are not rolled back, because gallery deletion is not reliable through the save API. Every generation writes new files (FR-2.9), so retry cannot overwrite earlier output. `Discard` on failure deletes the temp files. Save semantics follow [ADR-0005](0005-photo-picker-and-gallery-save.md), whose device verification is still open.

## Startup reconciliation

A single `StartupReconciler` runs once per process start, after the database is opened and before the UI accepts imports or generation. It removes files that no longer belong to anything. Crashes can happen between a file write and its database row, or between a row delete and its file delete, so cleanup cannot rely on the happy path.

| Target | Delete | Keep |
|---|---|---|
| `photos/` (files directory) | every `*.tmp` file, and every file whose relative path is not referenced by a photo row | files referenced by a row |
| `sheets/` (cache directory) | everything except `sheets/<jobId>/` for an existing job row ([ADR-0006](0006-background-generation.md)) | sheets of a resumable generation job |

- The step only touches these two directories. It must not scan the cache root, because the image picker plugin keeps its picked files there and `retrieveLostData()` ([ADR-0005](0005-photo-picker-and-gallery-save.md)) may still need them.
- Running before imports and generation are enabled means no in-flight file can be mistaken for an orphan.
- Each deletion is independent. A failure is logged and retried at the next start; it never blocks startup.
- It deletes files only. It never deletes or edits rows. A row without a file is reported (logged) and surfaced as an unavailable photo; see [ADR-0004](0004-photo-storage.md).
- The write orders that make this sufficient (file before row on import, row before file on remove) are defined in ADR-0004.

## Consequences

- Two more concepts to learn at once (Riverpod and drift) alongside Flutter itself.
- A `build_runner` step is required for drift's generated code.
- Repository interfaces sit between drift and the rest of the app, so the layer can be tested and replaced independently.
- The generation controller must be designed and tested as a state machine; Riverpod does not provide that structure by itself.
- The cache directory holds large temporary files during preview. Cleanup on cancel and done, and the startup reconciliation, are part of the design.
- The pure-Dart layout engine (`sheet_engine`) does not depend on either package.

## Open items

- `sqlite3_flutter_libs` is marked end-of-life (`0.6.0+eol`) on pub.dev. Older drift setup guides depend on it. Confirm drift's current Flutter setup against its official docs before adding dependencies.
- The image picker and gallery-save packages, and their Android scoped-storage verification, are covered in [ADR-0005](0005-photo-picker-and-gallery-save.md).

## Rejected alternative

`provider` + `sqflite`: faster to a first working screen and lighter, but async derived state gets awkward around the render and generation flow, and schema migrations are hand-written. Judged a worse fit for this app even though its schema is small.

## Related

- ADR-0001: Application framework (Flutter)
- ADR-0006: Background sheet generation
