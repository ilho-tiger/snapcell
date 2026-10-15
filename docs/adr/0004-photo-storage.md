# ADR-0004: Photo storage — copy in, downscaled

- Status: Accepted, pending #3 (EXIF capture date may be missing, which would make it nullable; ADR-0005 item 4 may replace the isolate downscale; do not build on these points as settled)
- Date: 2026-10-15
- Resolves: OQ-2 in `docs/requirements.md`

## Context

Users associate phone photos with diary dates (FR-1.1 to FR-1.3). The app must decide whether it keeps a *reference* to each photo in the phone gallery or stores its own *copy*.

Facts that shape the decision:

- The printed photo is small: about 343 × 224 px for a 29 × 19 mm photo rectangle at 300 DPI (FR-6.5). Phone originals are 12 MP or more, far beyond what is needed.
- A referenced photo can disappear from the gallery (deleted, moved, or access revoked). The requirements left the behavior at generation time undefined (gap in §7, "Missing photo at generation").
- There is no backup or export in v1 (§5). Uninstalling the app already loses associations, favorites and comments.
- Android scoped storage and photo-picker permissions make long-lived references to gallery items fragile. Package behavior is not yet verified.

## Options considered

| | Reference only | Copy in, full resolution | Copy in, downscaled | Reference + stored thumbnail |
|---|---|---|---|---|
| Photo disappears from gallery | Must handle: warning, and generation fails for that date | Not an issue | Not an issue | UI keeps working, but generation still needs the original |
| Permission and URI fragility | High | None after import | None after import | High |
| Storage per photo | None | Several MB | Roughly 300–500 KB | Small, but originals are still needed |
| Resolution available for generation | Original | Original | Capped | Original, if present |
| Works the same across frameworks | No | Yes | Yes | No |

## Decision

**Copy each photo into the app's private storage at import time, downscaled to about 1600 px on the long edge.**

- Downscaling runs in a background isolate so the UI stays responsive.
- The database stores the file path relative to the app's files directory (for example `photos/<id>.jpg`), resolved at read time, the original capture date (metadata only, FR-1.1), and the comment (FR-1.5).
- Each stored copy belongs to exactly one date. Picking the same gallery photo for another date is a separate import (FR-1.3).
- Generation reads only the stored copy. It never touches the gallery.
- Android Auto Backup is disabled (`android:allowBackup="false"`). With backup on, Android could restore the database without the photo files, or only some of them, and reintroduce dangling paths. Cloud backup also has a quota that a photo library would exceed, which fails silently. Backup is out of scope for v1 (§5); if added later it should be a deliberate feature.

1600 px on the long edge is far more than the roughly 343 × 224 px the default output needs. It also leaves headroom for larger cells or higher DPI settings: for example, a 100 mm cell at 400 DPI needs about 1575 px.

## Consequences

- The "photo vanished from the gallery" case no longer exists, so the missing-photo gap in §7 is resolved.
- No persistent gallery permissions or long-lived URIs are needed after import.
- Storage grows by roughly 300–500 KB per imported photo. This is acceptable for a diary app.
- If the user configures a cell or DPI so large that it exceeds 1600 px, output is upscaled and softer. The cap is a documented limit, and the value can be raised later if needed (existing copies would stay at their original cap).
- Deleting the original from the gallery has no effect on the app.
- Reinstalling or moving to a new device starts empty, the same as uninstalling (§5). Relative paths keep a later backup or export feature possible without a data migration.
- Because the stored copy is lossy-downscaled, re-importing is the only way to regain more resolution.
- Removing a photo from its date deletes its stored copy (FR-1.6), so no orphan files remain.
- Importing the same gallery photo twice creates two copies unless de-duplicated. De-duplication is not in scope for v1.

## Related

- ADR-0001: Application framework (Flutter)
- ADR-0002: State management and persistence (Riverpod + drift)
