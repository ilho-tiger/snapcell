# ADR-0008: Generation state machine and render-output lifecycle

- Status: Accepted (2026-10-17; the ADR-0006 open items it depended on are resolved by [spike 003](../spikes/003-foreground-service-render.md). The schema in ADR-0009 is still Proposed)
- Date: 2026-10-15
- Consolidates: ADR-0002 (Generation flow) and ADR-0006 (Render and resume, After rendering, Startup reconciliation)
- Amends: ADR-0006 (adds one `failure` column to `generation_job`; see [ADR-0009](0009-data-model.md))

## Context

The generation flow (FR-2.x) is described in two ADRs. ADR-0002 defines the controller states, and ADR-0006 adds a persisted job, a service and resume rules. Neither gives one authoritative transition table, and the word `Failed` covers two different cases (a render that cannot finish, and a save that partly failed). This ADR fixes the states, who may move between them, and what happens to the sheet files at each step.

## Decision

The flow has two layers, joined at one point.

### Layer 1: pre-job (in memory, foreground)

`Configuring → ResolvingFavorites → ConfirmingEmpties`, then **Start**.

- `Configuring` validates the configuration and range (FR-6.9). Invalid input stays here with the full error list.
- `ResolvingFavorites` is skipped when no date is ambiguous. `ConfirmingEmpties` is skipped when no date is empty.
- A favorite chosen in `ResolvingFavorites` is written to the database at once (FR-2.2, FR-2.10).
- Cancel discards the in-memory state. Nothing else exists to clean up.
- A kill in this layer loses only the in-progress flow. Chosen favorites remain.

**Start** (user confirms) is the only crossing point. In one transaction it inserts the `generation_job` row (state `rendering`, config snapshot, render plan) and one `generation_sheet` row per sheet (status `pending`), then starts the service (ADR-0006). From here on the database is the source of truth, and the UI observes it through drift streams.

### Layer 2: job (persisted)

Job states: `rendering`, `ready`, `saving`, `failed`. `Done` is the absence of a job (rows and files deleted). At most one job exists (ADR-0006).

| From | Event | To | Written by |
|---|---|---|---|
| `rendering` | last sheet rendered | `ready` | service |
| `rendering` | photo unavailable, or render error | `failed` (`failure` set) | service |
| `ready` | user taps Save | `saving` | foreground |
| `saving` | all sheets `saved` | Done | foreground |
| `saving` | some sheets `failed` after the last attempt | `failed` | foreground |
| `failed` with failed sheets | Retry | `saving` (failed sheets only) | foreground |
| `rendering`, `ready`, `failed` | Cancel or Discard | Done | either |
| `saving` | Cancel | Done (saved sheets stay in the gallery) | foreground |

- `failed` has two causes, distinguished by `failure`: `photos_missing` (dates listed, FR-2.14) and `save_failed`. Only `save_failed` offers Retry. `photos_missing` offers Discard only, because the plan refers to photo ids that no longer exist. Re-adding a photo creates a new id.
- Cancel and Discard are one operation: delete the job rows in a transaction, then delete `sheets/<jobId>/` (row before file, as in ADR-0004).
- **Single writer per transition.** The service moves only `rendering` forward and sets `pending → rendered`. The foreground owns everything from `ready` on. The one shared operation is Cancel, and it is safe because it only deletes.
- **Cancel while the service is rendering.** Before each sheet and again after its rename, the renderer checks that the job row still exists. If the row is gone it deletes its own file and stops. The service never recreates a deleted job.

### Recovery after a kill

Handled by `StartupReconciler` (ADR-0002) before the UI accepts imports or generation.

| Job state at kill | On next start |
|---|---|
| `rendering` | Resume: re-render only `pending` sheets, or `rendered` sheets whose file is missing (ADR-0006) |
| `ready` | Open the preview |
| `saving` | If every sheet is `saved`, finish as Done. Otherwise treat in-flight sheets as unsaved and move to `failed` (`save_failed`), so the user gets Retry or Discard |
| `failed` | Show the failure screen |

A retry after a kill may duplicate one sheet in the gallery. This is accepted over a silently missing sheet (ADR-0006).

`rendering` is also resumed without a user start, by two other paths (spike 003):

- **System restart.** After a process kill, Android restarts the foreground service by itself (observed about 5 s later, with no UI). It resumes from the database exactly as above.
- **Service timeout.** At the `dataSync` timeout the service is stopped mid-run and the job stays `rendering`. The next app start resumes it.

Because of the system restart, a service run and `StartupReconciler` can both try to resume. **One runner per job:** the reconciler starts the service only when it is not already running. The window where a system restart lands between that check and the start is not verified, and two runners writing the same `p<n>.jpg.tmp` could corrupt a sheet. The implementation must close it (for example a per-sheet claim in the database) and test it.

## Render-output lifecycle

Per sheet, the file and its row move together, with the file always first (ADR-0004's write order).

| Step | File (`sheets/<jobId>/`) | Row status |
|---|---|---|
| Planned | none | `pending` |
| Encoding | `p<n>.jpg.tmp` | `pending` |
| Rendered | `p<n>.jpg` (rename of the temp file) | `rendered` |
| Save in flight | `p<n>.jpg` | `rendered` |
| Saved | `p<n>.jpg` | `saved`, `saved_uri` set |
| Save failed | `p<n>.jpg` | `failed`, `error` set |
| Done, Discard or Cancel | directory deleted | rows deleted |

- A file with the final name is complete. A `.tmp` file is never trusted.
- `saved` sheets are never rolled back, because gallery deletion is unreliable (ADR-0002). Each generation writes new files (FR-2.9).
- Files are kept until the job ends, not until the preview closes, so that Retry never re-renders.
- Sheets are rendered once per job. Resumed and uninterrupted runs give identical output because the plan and config snapshot are fixed (ADR-0006).
- `sheets/` is cache storage. Only `sheets/<jobId>/` for an existing job row survives startup reconciliation.

## Consequences

- One transition table can be tested with `ProviderContainer` and a fake `SheetRenderer`. Every row above, and every kill recovery row, becomes a test case.
- The UI derives its screen from `(job state, failure, sheet statuses)`, not from a separate in-memory flag, so a relaunch shows the correct screen without extra code.
- `generation_job` gains a nullable `failure` column that ADR-0006 does not list.
- Cancel from the notification and from the UI are the same operation, so they cannot disagree.
- A job stuck in `failed(photos_missing)` blocks starting a new generation until the user discards it. Starting a new one prompts for exactly that (ADR-0006).

## Rejected alternatives

- **Separate `save_failed` and `render_failed` job states.** Same behavior as one `failed` state plus a `failure` value, with more transitions to test.
- **Cancel as a flag the renderer polls.** Needs a writer-ownership rule for the flag, and deleting the row already has the intended effect.
- **Delete sheet files when the preview closes.** Would force a re-render on retry.

## Related

- ADR-0002: State management and persistence (Riverpod + drift)
- ADR-0004: Photo storage — copy in, downscaled
- ADR-0005: Photo picker and gallery save
- ADR-0006: Background sheet generation
- ADR-0009: Data model
