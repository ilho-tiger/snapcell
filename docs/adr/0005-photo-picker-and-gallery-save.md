# ADR-0005: Photo picker and gallery save — `image_picker` + `gal`

- Status: Proposed (docs and source reviewed; on-device verification pending, see checklist)
- Date: 2026-10-15
- Resolves: the deferred package choice in ADR-0001 (Consequences) and ADR-0002 (Consequences)

## Context

Import (FR-1.1 to FR-1.3) and save (FR-6.7) both cross into platform APIs. ADR-0004 fixes the import contract: each picked photo is copied into app-private storage once, so the picker only needs a one-shot read and no long-lived URIs or gallery permissions. FR-6.7 needs the finished JPEG written to the gallery, and FR-6.4 needs the JFIF density bytes to survive that write.

**Minimum supported Android version is 16 (API 36)**, decided 2026-10-15. This removes every pre-scoped-storage code path from the decision below. The requirements doc should record it as a constraint.

Package status checked on pub.dev on 2026-10-15:

| Package | Latest | Published | Pub points | Notes |
|---|---|---|---|---|
| image_picker | 1.2.4 | 2026-10-06 | 160/160 | Published by flutter.dev; Android min SDK 24 |
| file_picker | 13.1.0 | 2026-09-15 | 160/160 | Generic file browser, not a gallery picker |
| photo_manager | 3.12.0 | 2026-08-09 | 160/160 | Full gallery access (needs media permissions) |
| wechat_assets_picker | 10.1.3 | 2026-07-19 | 155/160 | Custom picker UI on top of photo_manager |
| gal | 2.3.3 | 2026-07-25 | 160/160 | Android min SDK 21 |
| image_gallery_saver | 2.0.3 | 2023-07-03 | 150/160 | Stale for 3+ years |
| image_gallery_saver_plus | 5.1.1 | 2026-07-14 | 160/160 | Fork of the above, 120 likes |
| saver_gallery | 5.1.0 | 2026-05-29 | 160/160 | 79 likes; requires Flutter >= 3.44 |
| media_store_plus | 0.1.3 | 2024-09-22 | 160/160 | Android only, low-level MediaStore |

## Options considered

### Photo picker

| | image_picker | photo_manager / wechat_assets_picker | file_picker |
|---|---|---|---|
| Android mechanism | System Photo Picker on Android 13+ (always on 16+, opt-in below); `ACTION_GET_CONTENT` otherwise | `MediaStore` query, in-app UI | Storage Access Framework |
| Runtime permission | None | `READ_MEDIA_IMAGES` or equivalent | None |
| Fits ADR-0004 (copy in once) | Yes: returns a cached file path | Yes, but the permission is not needed | Yes, but not gallery-oriented |
| Multi-select | `pickMultiImage` (the `limit` option needs `useAndroidPhotoPicker = true`) | Yes | Yes |
| Maintainer | flutter.dev | Community | Community |

### Gallery save

| | gal | image_gallery_saver_plus / saver_gallery | media_store_plus |
|---|---|---|---|
| Android >= 30 write path | `MediaStore` insert with `RELATIVE_PATH`, no permission | Not reviewed | Yes |
| Android <= 29 | `WRITE_EXTERNAL_STORAGE` (declared with `maxSdkVersion`) | Not reviewed | Yes |
| Bytes written unmodified | Yes for `putImage(path)`: stream copy | Not reviewed | Yes |
| Maturity | 593 likes, 663k downloads | 120 / 79 likes | Pre-1.0 |

## Decision

**Use `image_picker` for import and `gal` for gallery save.** Neither is needed beyond the two calls below, so both stay behind thin app-level interfaces (`PhotoImporter`, `SheetSaver`) so tests can fake them and a swap stays local.

### Import

- Call `pickMultiImage` (FR-1.2 wants several candidates per date). On Android 16 the plugin always uses the system Photo Picker, so `useAndroidPhotoPicker` needs no setting and `limit` is honored.
- No gallery permission is requested. The Photo Picker hands back only what the user selected, which matches ADR-0004: nothing is read after import.
- Picks are returned as files in the app cache. ADR-0004's copy-and-downscale step moves them to private storage; the cache file is then disposable.
- Call `retrieveLostData()` at startup. Android may kill the activity while the system picker is in the foreground.
- Capture date (ADR-0004, FR-1.1) is **not** taken from `XFile.lastModified`: the cached copy's timestamp is the copy time, not the capture time. It is read from EXIF `DateTimeOriginal` of the picked file. The EXIF reader package is not chosen here; see Open items.

### Save

- Call `Gal.putImage(path)` with the file produced by the encoder, passing the FR-6.6 file name. `putImage` stream-copies the file, so the JFIF density bytes patched for FR-6.4 are written to the gallery unmodified. `putImageBytes` is avoided: it re-guesses the format from the bytes and adds no benefit here.
- Pass `album: 'Snapcell'` so output is grouped and easy to find when printing. With API 36 this inserts into `Pictures/Snapcell` through `MediaStore` `RELATIVE_PATH`, with no permission.
- Manifest: no storage permission and no `requestLegacyExternalStorage`. Do not copy those lines from `gal`'s README; they are for API 29 and below.
- Access checks are unnecessary (`gal` returns true without a prompt above API 29). Still catch `GalException`.
- Map `accessDenied`, `notEnoughSpace` and `notSupportedFormat` to user-facing messages.

## Consequences

- Neither package requires a runtime permission or manifest storage entry at the minimum SDK.
- `image_picker` is first-party (flutter.dev), which is the strongest maintenance signal available for the riskiest platform dependency.
- `gal` is community-maintained with a single main maintainer. It has no blocking issue in the reviewed source, and the interface boundary limits the cost of replacing it.
- `gal` copies the whole file through an 8 KB buffer on a background thread. A 1200 × 1650 JPEG is well under 1 MB, so this is not a concern.
- `gal` depends transitively on `org.apache.commons:commons-imaging:1.0-alpha3` on Android (used for format detection in `putImageBytes`). It is a small size cost, but pinned to an alpha release.
- `gal` does not set `IS_PENDING` while writing, so a gallery app could briefly see a partially written file. Output is small, so the window is short.
- Pin exact versions in `pubspec.yaml` once the app skeleton exists, and re-run the checklist below on any upgrade.

## Open items (must be verified on a device before status becomes Accepted)

Reviewed from docs and source only. Flutter is not installed in the authoring environment, so nothing below has been run.

1. **FR-6.4 round trip**: save a JPEG with patched density (300 DPI) via `Gal.putImage`, pull it from the device, and confirm the density bytes are unchanged.
2. **Scoped storage on Android 16**: confirm `Pictures/Snapcell/` appears in the system gallery with no permission prompt, and that a second save of the same file name gets a unique name rather than overwriting.
3. **EXIF through the Photo Picker**: confirm `DateTimeOriginal` is present in the cached file returned by `pickMultiImage`. If it is stripped on some Android versions, FR-1.1's capture date falls back to "unknown" and ADR-0004's schema needs to allow null.
4. **Orientation and resizing**: `image_picker` can resize natively with `maxWidth`/`maxHeight` (it subsamples while decoding since 0.8.13+25) and copies EXIF tags on resize. Confirm that EXIF orientation is applied correctly on a rotated portrait photo. If it is, native resizing to 1600 px could replace the isolate downscale in ADR-0004, which is simpler. This is a possible change to ADR-0004, not made here.
5. **MainActivity destruction**: force-kill the app while the picker is open (developer option "Don't keep activities") and confirm `retrieveLostData()` restores the selection.
6. **EXIF reader package**: choose and verify one (pub.dev status, Android behavior) for item 3.

## Rejected alternatives

- **photo_manager / wechat_assets_picker**: gives a custom in-app gallery UI, but requires media-read permission and a permission-denied flow, in exchange for nothing ADR-0004 needs.
- **file_picker**: not gallery-oriented, and `image_picker` already covers the case.
- **image_gallery_saver**: last release 2023; the maintained forks have far less adoption than `gal`.
- **media_store_plus**: low-level, pre-1.0, and would reimplement what `gal` already does.

## Related

- ADR-0001: Application framework (Flutter)
- ADR-0002: State management and persistence (Riverpod + drift)
- ADR-0004: Photo storage — copy in, downscaled
