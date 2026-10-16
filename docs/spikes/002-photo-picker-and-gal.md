# Spike 002: Photo Picker EXIF and `gal` gallery save

- Issues: [#3](https://github.com/ilho-tiger/snapcell/issues/3) (Photo Picker, EXIF, resize, bulk, lost data) and [#4](https://github.com/ilho-tiger/snapcell/issues/4) (`gal` save)
- Date: 2026-10-16
- Verifies: [ADR-0005](../adr/0005-photo-picker-and-gallery-save.md) open items 1–6, with input for [ADR-0004](../adr/0004-photo-storage.md) (downscale, capture date)
- Code: directory `spike/exif_spike/` on branch `spike/photo-picker-gal`, commit `b3ddc6c` plus the later "retrieveLostData now" and "EXIF read check" buttons (throwaway, never merged to `main`; keep the branch so the numbers stay reproducible)
- Status: **done on the S25 (Android 17, API 37). Not run on API 36.** The ADR minimum is Android 16, so see Not verified. ADR-0004 and ADR-0005 are updated accordingly.

## Question

1. Does `image_picker` (Android Photo Picker) keep the EXIF capture date, and what does it do to GPS and orientation (#3)?
2. Can native `maxWidth`/`maxHeight` resize replace the pure-Dart isolate downscale in ADR-0004, for large photos and bulk imports (#3)?
3. Does `retrieveLostData()` recover a pick after Android kills the app (#3)?
4. Does `Gal.putImage` write the JPEG unmodified, with no permission, into `Pictures/Snapcell/`, without overwriting on a repeated name (#4)?

## Method and setup

| | |
|---|---|
| Device | Galaxy S25 `SM-S931U1`, Android 17 (API 37), 11 GB RAM, over wireless debugging |
| Build | `flutter build apk --profile`, Flutter 3.47.7 |
| Packages | `image_picker` 1.2.4 (`image_picker_android` 0.8.13+25), `gal` 2.3.3, `image` 4.12.0 |
| Host tools | `exiftool` 13.55 for metadata, `shasum`, `adb pull` |

The app (`spike/exif_spike/lib/main.dart`) has one button per case and logs `SPIKE ...` lines to logcat. Every picked file is copied from the app cache to `/sdcard/Android/data/dev.snapcell.spike.exif_spike/files/out/`, hashed, and pulled with `adb pull` for comparison on the Mac. Memory comes from host-side `adb shell dumpsys meminfo` every 0.3 s (PSS, Graphics), one fresh process per run.

**Timing method.** The stopwatch inside the app includes the time the user spends in the picker, so it is useless for processing time. Processing time is the gap in logcat between the Photo Picker's `wm_finish_activity` event and the app's `SPIKE PICK` line. It includes the plugin's resize and the copy to cache, and is accurate to roughly 50 ms.

**Fixtures.** Real photos are the user's private S25 camera photos. They were not opened, and are not committed or reproduced here. Synthetic fixtures (not private) were made with `exiftool`:

- `a.jpg`: 3000×2000 image with four colored quadrants, a black bar and a white marker block, `DateTimeOriginal` 2024-03-05 14:22:10 +01:00, GPS 48.1 N 11.5 E, orientation tag 6.
- `synth_o1/o3/o6/o8.jpg`: the same pixels with orientation tag 1, 3, 6, 8, so the correct display position of the marker is known.
- `big50.jpg`: a 6120×8160 (50 MP) upscale of a camera photo. It has no real 50 MP sensor data, but decode memory and time depend on pixel dimensions, not on how the image was produced.
- `diary_2026-10-01_2026-10-18_p1.jpg`: 1200×1650, JFIF density set to 300 inches (bytes `01 012c 012c`), SHA-256 `1ec72301…bbd2`.

### Limits

- One device, API 37 only. See Not verified for API 36.
- Only JPEG was tested. This S25's camera produces JPEG by default, and `DCIM/Camera` held no HEIC.
- The 50 MP file is synthetic, so the file size (4.8 MB) is not representative of a real 50 MP photo.
- Photos from outside the camera (screenshots, downloads, messenger images) were not tested for EXIF.
- Memory sampling every 0.3 s over Wi-Fi can miss short peaks.

## Results

### 1. Capture date through the Photo Picker: pass (#3)

Unresized pick (`pickMultiImage` without options) of 19 real camera photos plus synthetic fixtures:

- `DateTimeOriginal`, `OffsetTimeOriginal` and `Orientation` are identical to the original on the phone, compared tag by tag for 18 of the 19 camera photos. For the 19th the original could not be located by file name.
- For the one real photo compared byte by byte, the picked file is the same size as the original and only 26 bytes differ, all in the GPS fields.
- All 40 files of the 40-photo run also carry `DateTimeOriginal`.

### 2. GPS: stripped (#3)

The picked file's GPS block is **zeroed, not removed**: latitude and longitude are empty, and the version ID reads 0.0.0.0, so the byte length is unchanged and the SHA-256 differs from the original. After a native resize some readers show it as `0 deg 0' N, 0 deg 0' E`, so a naive reader would see a position at 0°,0°. The app stores no GPS (ADR-0004), so this is a privacy benefit, and nothing needs the data. Do not read GPS from picked files.

### 3. Orientation and native resize (#3, ADR-0005 item 4)

- **Real S25 photos carry orientation tags.** Of the 19 camera photos, 10 were 4000×3000 with tag 6 (Rotate 90 CW), 1 had tag 3 (Rotate 180), 8 had tag 1. Spike 001's photos had no tags; this set did.
- **Native resize does not bake the rotation.** It scales the stored pixels (4000×3000 to 1600×1200) and copies the tags, including the orientation tag. The result is still "landscape pixels plus a rotate tag".
- **Both decoders on this device honor the tag.** The synthetic set was decoded with Flutter's `instantiateImageCodec` (also with `targetWidth: 343`) and with `image` 4.12's `decodeJpg`. The white marker block lands at the correct display position for tags 1, 3, 6 and 8 in both (for example tag 6: (0.79, 0.08), expected (0.80, 0.08)). A screenshot of `Image.file` confirmed it visually on the synthetic files.
- **No double rotation.** `decodeJpg` applies the rotation and clears the tag (the `exifOrientation` it reports is null), so `bakeOrientation` afterwards changes nothing. Re-encoding with `image` therefore writes upright pixels with no tag.

### 4. 50 MP photo: native resize vs pure-Dart isolate (#3)

Same input: `big50.jpg`, 6120×8160.

| | Native `maxWidth/Height: 1600` | Pure-Dart isolate (`image` 4.12, `copyResize` average, JPEG q85) |
|---|---|---|
| Result | 1200×1600, `DateTimeOriginal` kept, GPS zeroed | 1200×1600 |
| Time | about 217 ms (picker close to result) | 1,813 ms (decode 1,424, resize 261, encode 79) |
| Peak PSS over idle | +40 MB (199 → 239 MB) | +138 MB (229 → 367 MB) |
| Output size | 1.1 MB (default `imageQuality`) | 299 KB (quality 85) |
| Out of memory | no | no |

Both work on the S25 (11 GB RAM). The native path is about 8× faster and uses about a third of the memory. A first attempt at the Dart run was invalid: the failed isolate closure and an `Image.file` preview in my harness (it decoded the full 50 MP image for display, peak 528 MB) were harness defects, not product results, and were fixed before the numbers above were taken.

### 5. Output size and quality (#3, ADR-0004)

- `imageQuality` unset: real 12 MP photos resized to 1600 px came out at about **960 KB** each. That is roughly 2–3× the ADR-0004 estimate of 300–500 KB.
- `imageQuality: 85`: 20 photos (19 real, 1 synthetic 50 MP) at 1600 px averaged **271 KB** (143–415 KB); 40 photos averaged **259 KB** (130–434 KB). This fits the estimate.
- Generation loss from re-compression at quality 85 was not compared visually (private content).

### 6. Bulk import (#3)

All runs on the same 19 most recent camera photos plus `big50.jpg` (and 20 more older photos for the 40 run).

| Run | Files | Processing (picker close to result) | Peak PSS over start |
|---|---|---|---|
| Raw, no resize | 20 | about 420 ms | +0 MB (241 → 241) |
| `maxWidth/Height 1600`, q85 | 20 | about 1.9 s | +57 MB (215 → 272) |
| `maxWidth/Height 1600`, q85 | 40 | about 3.8 s | +129 MB (243 → 372) |

- **`limit` is honored.** With `limit: 40` the picker let the user select 40 and stopped them at exactly 40.
- **UI responsiveness:** an 8 ms Dart timer logged no gap over 50 ms during the 40-photo run. The resize runs on the plugin's native thread, so the Dart event loop was not expected to block. Platform-thread jank was not measured.
- The memory peak grows with batch size; it may reflect garbage that is collected lazily. It stays well under 400 MB on this device.

### 7. Lost data recovery (#3, ADR-0005 item 5): works, with two caveats

"Don't keep activities" alone did not destroy the app's activity while the picker was open. The Photo Picker is shown as a translucent bottom sheet, which most likely means the activity beneath it is only paused, never stopped (no destroy event appeared in the activity log). To get a real process death, the app was sent to the background while the picker was open (activity destroyed with reason `always-finish`, then `am kill` killed the process, reason `kill background`), and the picker was brought back from Recents.

- The pick result was **recovered**: `retrieveLostData()` returned `isEmpty=false`, `type=image`, one file with the same SHA-256 as the raw pick of `a.jpg`.
- **Caveat 1: timing.** In this flow Android restarted the app (and its startup call) while the picker was still open, so the startup call returned empty. The same call made after the pick finished returned the file. A true low-memory kill restarts the app after the picker closes, and a startup call would see it. To be safe, call `retrieveLostData()` again when the app resumes, not only at startup.
- **Caveat 2: not resized.** The pick was made with `maxWidth/maxHeight 1600`, but the recovered file is **unresized** (117,734 bytes, the same as the raw pick; the resized version is 26 KB). The import pipeline must accept a full-size file on the recovery path.
- **Without the startup call:** the original `pickMultiImage` future never completes after a process death (no `SPIKE PICK` line appeared), so the app never learns of the pick. The result stays in the plugin's cache.
- One earlier attempt returned empty on the later call; I could not tell whether the user tapped Add or Cancel, so it is not counted.
- A kill of the app process while the picker was foreground-adjacent (`am kill` with the picker open) did nothing; the process stays alive then. This is not reproducible with `adb` and is out of scope.

### 8. EXIF reader (#3, ADR-0005 item 6): `image` package

`image` is already a dependency of the encode pipeline (ADR-0001). `decodeJpgExif(bytes)` read `DateTimeOriginal` (`exifIfd` tag 0x9003), `OffsetTimeOriginal` (0x9011) and the orientation tag from 22 files (the 20 files of the raw bulk pick, which are 19 real camera photos and `big50.jpg`, plus `a.jpg` and `synth_o3.jpg`). All matched `exiftool`. Cost was 0.2–7 ms per file (the first call, which includes warm-up, was the slowest), even on 6 MB files, because it does not decode pixels. No separate EXIF package is needed. `DateTimeOriginal` is a local wall-clock string; the date-only value ADR-0009 stores is its first 10 characters.

### 9. `gal`: JPEG saved unmodified (#4, ADR-0005 item 1): pass

`Gal.putImage(path, album: 'Snapcell')` with `diary_2026-10-01_2026-10-18_p1.jpg`:

- SHA-256 of the file pulled from `/sdcard/Pictures/Snapcell/` equals the original (`1ec72301…bbd2`), 367,225 bytes.
- JFIF header bytes in the saved file: `ff d8 ff e0 00 10 4a 46 49 46 00 01 01 01 01 2c 01 2c`, unit 1, density 300 × 300.

### 10. Scoped storage and duplicate names (#4, ADR-0005 item 2): pass

- **No permission:** no dialog appeared, the app stayed in the foreground, and `dumpsys package` lists only `INTERNET`, `ACCESS_LOCAL_NETWORK` and a dynamic-receiver permission. No storage permission was declared or requested.
- **Location:** `/sdcard/Pictures/Snapcell/`, MediaStore `relative_path = Pictures/Snapcell/`, `owner_package_name` is the app, `is_pending = 0`.
- **Gallery app:** the user confirmed that a Snapcell album appears in the gallery and shows a 1200×1650 picture. The count of two images was not verified in the UI.
- **Second save of the same name:** a new file `diary_2026-10-01_2026-10-18_p1 (1).jpg` was created; the first file is unchanged (same size, timestamp 14:48). This matches the form ADR-0005 expected.
- **`Gal.putImage` returns `Future<void>`.** It does not report the name or URI the gallery assigned. ADR-0005 and ADR-0002 expected the app to record the assigned name (`saved(uri)`); with `gal` that requires a separate MediaStore query, or not recording it.

### 11. Error path (#4): observed

`Gal.putImage('/nonexistent/<name>.jpg', album: 'Snapcell')` throws `GalException` with `type = GalExceptionType.notSupportedFormat` ("Unsupported file formats"), not a not-found or access type. Nothing was written. A missing file therefore maps to the same type as an unsupported format, so a user-facing message for `notSupportedFormat` should not claim the format is wrong. The `accessDenied` and `notEnoughSpace` types were not triggered.

## Conclusion

1. **Capture date survives** the Photo Picker (identical date, offset and orientation). GPS is zeroed. ADR-0009 already stores the capture date as nullable, so no schema change; the null path still matters for photos without EXIF (not tested).
2. **Native resize can replace the isolate downscale** for normal imports: about 8× faster and a third of the memory at 50 MP, and 1.9 s for 20 photos. Set `imageQuality: 85`; the default gives about 960 KB files.
3. **A Dart downscale is still needed** for the recovery path, because `retrieveLostData()` returns the unresized file. At about 1.8 s for 50 MP it is acceptable for that rare case.
4. **Orientation is safe** with the stored copy as produced: native resize keeps the tag, Flutter and `image` 4.12 both apply it on decode, and re-encoding with `image` bakes it with no double rotation.
5. **`gal` saves byte for byte** with no permission, in `Pictures/Snapcell/`, and de-duplicates with `(1)`. It cannot tell the app the assigned name.
6. **`image` reads the EXIF** needed; no new package.

## Not verified

- [ ] **API 36 (Android 16).** Everything ran on API 37. The emulator `snapcell_pixel` (API 36) was not used; behavior of the Photo Picker and MediaStore is expected to match but is unconfirmed.
- [ ] **HEIC.** The camera produced JPEG only. Whether `pickMultiImage` returns HEIC or converts it is untested.
- [ ] **Photos without EXIF** (screenshots, downloads, messenger images), and photos edited in the gallery app.
- [ ] A **real 50 MP camera photo** (the 50 MP file is synthetic).
- [ ] Visual quality of native-resized and quality-85 photos (private content), and generation loss.
- [ ] A **true low-memory kill** of the app while the picker is shown (reproduced by background plus `am kill`; the restart order differed from a real kill).
- [ ] `gal` error types `accessDenied` and `notEnoughSpace`.
- [ ] Number of items in the Snapcell album in the gallery UI (two expected).
- [ ] Platform-thread (UI) jank during bulk resize.

## Follow-ups

- ADR-0004 and ADR-0005 are updated in this PR; see their status lines and changes.
- Decide how to record the saved name (ADR-0002 `saved(uri)`): MediaStore query after `putImage`, or drop the field.
- If HEIC or non-camera photos matter, run them before the iPhone work.

## Reproduce

Check out `spike/photo-picker-gal` first.

```
cd spike/exif_spike
fvm flutter build apk --profile
adb install -r build/app/outputs/flutter-apk/app-profile.apk
adb logcat -c; adb logcat -d | grep SPIKE
adb pull /sdcard/Android/data/dev.snapcell.spike.exif_spike/files/out/ out/
```

Push test fixtures to `/sdcard/Pictures/Spike002/` and run the media scanner broadcast to see them in the picker. Push the 300 DPI file and `big50.jpg` to `<files dir>/fixtures/`, and files for the EXIF read check to `<files dir>/exifcheck/`. The picker needs a person at the phone; timing is the gap between the picker's `wm_finish_activity` event (`adb logcat -b events`) and the `SPIKE PICK` line.
