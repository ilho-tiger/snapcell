# ADR-0006: Background sheet generation — foreground service, resumable per sheet

- Status: Proposed (no code or device run yet; see Open items)
- Date: 2026-10-15
- Amends: ADR-0002 (Generation flow, Startup reconciliation)

## Context

A range can need many sheets, and each one is rendered at print DPI and JPEG-encoded. That takes long enough that the user will switch apps or lock the phone. Two problems follow:

- Generation must not block the UI and must keep running while the app is not in the foreground. The user gets a notification when it is done.
- Android can still kill the process mid-run. ADR-0002 assumed the whole run is lost in that case: `sheets/` is wiped at startup.

Android constraints (Android 16 is the minimum, see [ADR-0005](0005-photo-picker-and-gallery-save.md)):

- A background process is cached and killed freely. Long work needs a **foreground service** with a visible notification, and Android 14+ requires a declared foreground service type.
- A foreground service cannot be started from the background (Android 12+). Generation starts from a user tap, so this is satisfied.
- Posting a notification needs the runtime `POST_NOTIFICATIONS` permission on API 33+. Without it the service still runs, but the notifications are not shown.
- Swiping the app from recents destroys the activity and its Flutter engine. Work that lives in the activity's isolate dies with it, even if the process stays.

## Options considered

| | Foreground service | WorkManager | Keep in the UI isolate |
|---|---|---|---|
| Survives app in background | Yes | Yes | No |
| Survives swipe from recents | Yes (own isolate) | Yes | No |
| Survives process death | No, so the job must be resumable | Yes, rescheduled | No |
| Runtime limits | Type-specific timeout | About 10 min per worker unless run as a foreground service anyway | None while foreground |
| `dart:ui` render path (ADR-0001) | Needs a spike (see Open items) | Same, in a headless engine | Works |

## Decision

**Run rendering in a foreground service, and make the job resumable at sheet granularity.**

### What moves to the background

Only `Rendering` (ADR-0002) runs in the service. `ResolvingFavorites` and `ConfirmingEmpties` are interactive and stay in the foreground. The service starts when the user confirms, and renders from a **render plan** the controller has already resolved.

- **Render plan:** an ordered list of sheets, each an ordered list of `(date, photo id)` units, plus a snapshot of the configuration used (paper, DPI, margins, labels, and so on). It is persisted with the job. A later configuration edit or favorite change never alters a job already started.
- **Service isolate:** the foreground service runs its own isolate with a drift connection to the same database file, so it survives the activity being destroyed. The UI reads job progress from drift streams, not from a handle on the service.
- **Package:** a foreground-service plugin that provides a Dart task isolate, such as `flutter_foreground_task`, plus `flutter_local_notifications`. Neither is verified here; choose and pin them in the spike.
- **Foreground service type:** declare `dataProcessing` (Android 15+) in the manifest. Its timeout callback must persist state and stop the service promptly. The job is then resumed at the next app start, or by the user from the notification.

### Persistence

Two drift tables, owned by a `GenerationJobRepository`:

| Table | Columns | Notes |
|---|---|---|
| `generation_job` | id, state, range start/end, config snapshot, render plan, created at | `state`: `rendering`, `ready`, `saving`, `failed` |
| `generation_sheet` | job id, sheet index, status, saved uri, error | `status`: `pending`, `rendered`, `saved`, `failed` |

At most one job exists at a time. Starting a new generation while a job exists asks the user to resume or discard it.

### Render and resume

- Sheet files are written under `sheets/<jobId>/`, to `p<n>.jpg.tmp` and then renamed to `p<n>.jpg`. A file with the final name is complete, so a kill mid-encode never leaves a plausible but truncated sheet.
- After the rename, the sheet row is set to `rendered`. File before row follows ADR-0004's write order.
- Resume re-renders only sheets whose row is `pending`, or whose row is `rendered` but whose file is missing. Rendering is deterministic for a given plan, so resumed and uninterrupted runs give the same sheets.
- If a photo in the plan is no longer available when resuming (FR-1.6 removed it, ADR-0004), the job moves to `failed` with the affected dates listed. The app does not silently drop or substitute units.

### Notifications

| When | Channel | Content | Actions |
|---|---|---|---|
| While rendering | `generation_progress`, low importance, ongoing (this is the service notification) | "Rendering sheet *k* of *n*" | Cancel |
| Rendering finished | `generation_done`, default importance | "*n* sheets are ready to preview" | Tap opens the preview |
| Rendering failed | `generation_done` | Reason in one line | Tap opens the failure screen |

- The completion and failure notifications are not posted while the app is in the foreground. The UI moves to the next state directly.
- Without `POST_NOTIFICATIONS`, the same result is shown as an in-app banner on the next launch. The permission is requested when the user first confirms a generation, with a short explanation, and a denial never blocks generation.
- All strings are translatable (FR-7.2).

### After rendering

The service stops once rendering ends. `Previewing` and `Saving` stay in the foreground and are unchanged (FR-2.8, FR-2.11, FR-2.12), except that per-sheet save status is now persisted in `generation_sheet`:

- Killed while `Previewing`: the job is `ready`, and the app reopens at the preview on the next start. The notification promised a preview, so the files must survive.
- Killed while `Saving`: sheets with `saved(uri)` stay saved. A sheet that was in flight is treated as not saved, so retrying may produce a duplicate in the gallery, which `gal` renames with a suffix (FR-6.6). A duplicate is accepted over a silently missing sheet.
- `Done` and `Discard` delete `sheets/<jobId>/` and the job rows. Cancel from any state before `Saving` completes does the same, including from the notification action (FR-2.11).

### Startup reconciliation

The `sheets/` row in the ADR-0002 table changes from "delete everything" to: keep `sheets/<jobId>/` while a `generation_job` row exists for it, and delete everything else. Jobs in `rendering` state resume as above. Everything else in that section is unchanged.

## Consequences

- The `Rendering` state of the ADR-0002 state machine is now a job in a service. The controller observes and commands it. Its transitions must still be testable with `ProviderContainer`, using a fake job runner behind a `SheetRenderer` interface.
- Render, resume, and reconciliation logic is plain Dart over interfaces (job repository, file system, renderer, notifier) and is tested with `dart test`, with no emulator.
- Two isolates open the same SQLite file. Writers must be short and the database must use WAL mode.
- The manifest gains the foreground service declaration, its type permission, and `POST_NOTIFICATIONS`. ADR-0005's "no permissions" consequence applies to import and save only.
- A killed process costs at most the sheet in progress, not the run.
- The foreground notification is visible for the whole render. That is the cost of Android allowing the work to continue.

## Open items (verify on a device before status becomes Accepted)

Tracked as the spike in [issue #5](https://gitlab.com/ilho-song/snapcell/-/work_items/5).

1. **Render path in a service isolate.** `Picture.toImage` from a non-UI isolate, with the activity destroyed, is unverified. If it does not work, fall back to compositing in a pure-Dart isolate with the `image` package, driven by `sheet_engine`. That fallback gives up ADR-0001's single painter shared by preview and export, and would amend ADR-0001.
2. **Foreground service type and timeout.** Confirm `dataProcessing` is the right type on Android 16, its timeout, and that `onTimeout` handling stops the service in time.
3. **Survival.** Run a 20-sheet job, then (a) background the app, (b) lock the screen, (c) swipe from recents, (d) `adb shell am kill` the process. Confirm (a) to (c) finish and (d) resumes at the next sheet.
4. **Notification permission denial.** Confirm the service and job still complete, and that the banner appears on the next launch.
5. **Package choice.** Confirm status and Android 16 behavior of the foreground-service and notification packages on pub.dev, then pin versions.
6. **Memory.** Peak memory of one sheet render in the service isolate on a low-RAM device.

## Rejected alternatives

- **WorkManager**: survives process death, but the render path in a headless engine is the same unknown, and long jobs end up as a foreground service anyway.
- **Rendering in the UI isolate with a keep-alive**: dies when the activity is swiped away.
- **Auto-save without preview**: would remove FR-2.8. The notification leads to the preview instead.
- **Restart from scratch after a kill**: simpler, but a long run can lose everything.

## Related

- ADR-0001: Application framework (Flutter)
- ADR-0002: State management and persistence (Riverpod + drift)
- ADR-0004: Photo storage — copy in, downscaled
- ADR-0005: Photo picker and gallery save
