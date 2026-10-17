# Spike 003: Background sheet rendering in a foreground service

- Issue: [#5](https://github.com/ilho-tiger/snapcell/issues/5)
- Date: 2026-10-17
- Verifies: [ADR-0006](../adr/0006-background-generation.md) open items 1–5 and 7. Item 6 (memory) is deferred.
- Code: directory `spike/fgs_spike/` on branch `spike/foreground-service-render`, commit `6e4f046` (throwaway, never merged to `main`; keep the branch so the numbers stay reproducible)
- Status: **done on an API 36 emulator.** The S25-only checks are deferred to the MVP system tests, and the risk is accepted (decision of 2026-10-17).

## Question

1. Can the sheet render path (`Picture.toImage`, JPEG encode) run in a foreground-service isolate with the activity destroyed?
2. Which foreground service type, and what happens at its timeout?
3. Does a 20-sheet job survive background, screen lock, swipe from recents and a process kill, and does it resume at the next sheet?
4. Do the service and job complete when `POST_NOTIFICATIONS` is denied?
5. Which package versions work?
6. Can the UI isolate read the drift database while the service isolate writes it (WAL)?

## Method and setup

| | |
|---|---|
| Device | AVD `snapcell_pixel`, Android 16 (API 36), arm64, rooted `adb` for `kill -9` |
| Build | `flutter build apk --profile`, Flutter 3.47.7, `targetSdk` 36 |
| Packages | `flutter_foreground_task` 11.0.3, `flutter_local_notifications` 22.3.2, `drift` 2.35.2, `drift_flutter` 0.3.1, `sqlite3` 3.5.2, `image` 4.12.0 |

The harness renders 20 sheets (1200×1650, 18 synthetic 1600×1200 photos each) with the spike 001 painter in a `TaskHandler`. Per sheet it writes `p<n>.jpg.tmp`, renames it, then sets the drift row to `rendered`. The UI shows progress from a drift stream and can run a read loop every 20 ms. At startup the UI resumes a job that is `rendering` with pending sheets, unless the service is already running. Everything logs `SPIKE ...` lines to logcat. The service isolate is told apart from the UI isolate by a per-isolate top-level tag (different values in the two, so they are separate isolates).

The cases were driven with `adb shell input` (`KEYCODE_HOME`, `KEYCODE_SLEEP`, `KEYCODE_APP_SWITCH` plus a swipe, `kill -9`, `am force-stop`).

## Results

### 1. Render path: pass

`toImage`, `toByteData` and the isolate JPEG encode work in the service isolate. This held in case (c) below, where the UI reported `AppLifecycleState.detached` mid-job and rendering carried on. Each sheet took about 250 ms to render and 82 ms to encode on the emulator (374–380 KB). These timings are not representative of the S25. ADR-0001 needs no amendment.

### 2. Service type and timeout

- `dataProcessing`, the type in the ADR, does not exist. The Android foreground service types page has no such type. It lists `dataSync` ("local file processing" is one of its uses) and `mediaProcessing`.
- `flutter_foreground_task` supports both (`ForegroundServiceTypes.dataSync`, `.mediaProcessing`). `dataSync` was used and works.
- `dataSync` has a 6 hour per 24 hour timeout. To trigger it, `device_config put activity_manager data_sync_fgs_timeout_duration 3000` was set. With the app in the foreground nothing fired. With the app backgrounded 1 s after the start, `onDestroy(isTimeout: true)` ran about 3 s later, and rendering stopped after sheet 10. The next app start resumed the job with 9 sheets pending.
- The in-flight sheet is abandoned when the engine goes away. The `.tmp` and rename step is what keeps a truncated file from looking complete.

### 3. Survival: pass

| Case | Result |
|---|---|
| (a) HOME 2 s after start | All 20 sheets finished with the app paused |
| (b) Screen off | All 20 finished |
| (c) Swipe from recents | UI `detached`, service kept running, all 20 finished |
| (d) `kill -9` mid-job | Android restarted the service itself about 5 s later (`starter=system`, new pid). It resumed with 12 pending, so the 8 finished sheets were kept. No UI was involved. |
| Force-stop mid-job | The service died and was not restarted. Reopening the app resumed it (11 pending) via the startup check. |

After (d) the output folder held 20 files, no `.tmp`, all with JPEG start and end markers, 1200×1650.

Caveat: (d) used `kill -9` as root on the emulator, which stands in for a low-memory kill. A real kill on the S25 is part of the deferred checks.

### 4. Notification permission denied: pass for the service

After `pm revoke ... POST_NOTIFICATIONS`, the service started, rendered all 20 sheets and stopped without an exception. No notification was posted (`dumpsys notification` empty). The in-app banner on the next launch is app logic and was not part of the harness.

### 5. Packages

Both packages resolve and build with Gradle 9.3.1 and Kotlin 2.4.0 (the Flutter 3.47.7 template). `flutter_local_notifications` fails the build until core library desugaring is enabled (`isCoreLibraryDesugaringEnabled = true` and `coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")`). `sqlite3_flutter_libs` is marked end-of-life on pub.dev (0.6.0+eol); `drift_flutter` 0.3.1 with `sqlite3` 3.5.2 does not need it.

### 6. SQLite across two isolates: pass

The UI isolate read the job and pending rows every 20 ms during renders (about 350 reads over one 7 s job, then continuing to 900 reads), while the service isolate wrote one row per sheet. Each isolate opened its own `driftDatabase` connection with `journal_mode=WAL` and `busy_timeout=0`. There were 0 read errors and no write errors.

## Limits

- API 36 emulator only. Samsung One UI power management is not covered.
- Emulator timings and memory are not representative (GPU memory is hidden), so item 6 of the ADR (memory) was not measured.
- The timeout was triggered with a shortened `device_config` value, not a real 6 hour run.
- `kill -9` came from rooted `adb`, which is not the same as the system's low-memory killer.
- The photos were synthetic.
- Not tested: tapping the done notification to open the preview, and the Cancel notification action beyond logging the button callback.

## Deferred to the MVP system tests (risk accepted 2026-10-17)

1. Samsung One UI battery management against the foreground service during a long render.
2. Cases (a) to (d) on the S25.
3. Memory and per-sheet timing on the S25.
