# Spike 001: Flutter JPEG export pipeline

- Issue: [#1](https://github.com/ilho-tiger/snapcell/issues/1)
- Date: 2026-10-16
- Verifies: [ADR-0001](../adr/0001-application-framework.md) (shared painter, encode, DPI), with input for [ADR-0004](../adr/0004-photo-storage.md)
- Code: branch `spike/jpeg-export`, directory `spike/` (throwaway, not for merge)
- Status: **partial.** Items 1–5, 7 and 8 were run on an emulator. Item 9 (physical print), a run on a real device and real photos are **not done**, so ADR-0001 stays "Accepted, pending #1".

## Question

Can `CustomPainter` → `PictureRecorder` → `Picture.toImage` → RGBA → JPEG in an `Isolate` produce a correct 1200 × 1650 sheet with declared DPI (FR-6.4), at acceptable speed and quality?

## Method and setup

A Flutter app (`spike/lib/main.dart`) runs the whole pipeline on startup and logs `SPIKE ...` lines to logcat. Sample outputs were pulled with `adb pull` and read back on the Mac with `sips` and a small Python JFIF/EXIF parser.

| | |
|---|---|
| Target | Android Virtual Device `snapcell_pixel`: Android 16 (API 36, google_apis, arm64), 4 cores, 2 GB RAM, `swiftshader_indirect` GPU |
| Host | Apple M5 Pro (the emulator runs arm64 code on the host CPU) |
| Build | `flutter run --profile`, Flutter 3.47.7, Impeller (OpenGLES), `image` 4.12.0 |
| Input photos | 18 **synthetic** 1600 × 1200 JPEGs (gradients, 2 px checker, 1 px lines, noise; about 1 MB each). No real photos were available on the emulator. |
| Painter | One `SheetPainter` that draws in 1200 × 1650 sheet space only: white background, 3 × 6 cells of 343 × 224 px (cover crop), label above each cell |
| Memory | Host-side `adb shell dumpsys meminfo` (PSS) sampled about every 0.3 s, plus in-process `ProcessInfo.currentRss` |

### Limits of this setup

- **Not the target device.** The target user has a Galaxy S26 (flagship), so a mid-range or low-RAM device is out of scope. The emulator still runs on the host CPU and its GPU is software-emulated, so it is not an S26 either: treat timings as relative, and the memory numbers as unreliable (item 8).
- Memory sampling at 0.3 s is coarse, and the emulator's GPU memory is probably not visible in PSS (see item 8).
- Synthetic photos have more high-frequency detail than most real photos, and no EXIF.
- During the run the app drew no frames (`runApp(SizedBox())`), so jank on a live UI was not tested. Only UI-isolate event-loop stalls were measured.

## Results

### 1. Encode quality and speed: pass (on emulator)

The pure-Dart `image` encoder, run in `Isolate.run` with the RGBA bytes passed as `TransferableTypedData`, produced a valid 1200 × 1650 JPEG (quality 92, about 480 KB with the synthetic photos).

| Step (one sheet, 18 photos) | Time |
|---|---|
| `Picture.toImage` (awaited) | 5–9 ms |
| `toByteData(rawRgba)` | 18 ms (105 ms on the very first, cold run) |
| JPEG encode in isolate | 72 ms |

`toImage` returns early, so the real raster cost shows up in `toByteData`. Quote the two together (about 25–115 ms). A run on a real device (ideally the S26) is still wanted.

### 2. DPI: pass, but the encoder does not do it by itself

- `image` 4.12.0 always writes a JFIF APP0 segment with **unit = 0, density 1:1** (aspect ratio only). The default output declares no DPI. See `jpeg_encoder.dart:687-700` in the package.
- Patching APP0 after encoding works: set byte 13 (unit) to 1 and bytes 14–17 to 300 (big-endian). Verified: APP0 reads `unit=1 x=300 y=300`, and `sips -g dpiWidth` reports 300.
- EXIF `XResolution`, `YResolution` (300/1) and `ResolutionUnit` (2 = inch) can be written through `image.exif.imageIfd`. Pitfall: the setters take a `Rational` or a `[numerator, denominator]` list. Passing an `IfdValueRational` is **silently dropped** (the first run lost both tags this way). Verified by parsing IFD0 of the output.
- macOS `sips` reads 300 DPI from either tag alone (JFIF-only and EXIF-only copies both report 300). With neither, it reports 72.
- Not checked: Android gallery apps and the printer app's print flow, which are the tools that matter. That belongs with item 9.

### 3. Downscale quality: use `medium` or `high`

Cell 0 (1600 × 1200 → 343 × 224) was rendered at each `FilterQuality` and compared with a box-filter (average) reference using mean absolute error over RGB (0–255). Images are in `001-jpeg-export/`.

| FilterQuality | MAE vs reference | Visual |
|---|---|---|
| `none` | 16.77 | strong aliasing (`cell_none.png`) |
| `low` | 13.02 | visible moiré on the fine pattern (`cell_low.png`) |
| `medium` | 7.57 | clean (`cell_medium.png`) |
| `high` | 7.57 | byte-identical to `medium` on this backend |

Use `FilterQuality.medium`. The remaining MAE comes mainly from the 2 px checker averaging to a slightly different gray than the mip chain. Re-check with real photos.

### 4. Preview and export parity: pass for geometry

- The painter draws only in sheet space. The preview applies `canvas.scale(0.3)`. A 0.3× preview compared with the export downscaled by a box filter gives MAE 1.79, with the same cell and label positions.
- Label layout is computed in sheet space (113.8 × 28.0 px for the test label), so it does not depend on preview scale.
- This supports the ADR-0001 follow-up wording: the shared painter guarantees **geometry** parity, not pixel parity. Text anti-aliasing differs at small scale.

### 5. Alpha: pass

After the opaque white first fill, the minimum alpha over all 1200 × 1650 pixels is 255. The JPEG has no alpha artifacts.

### 6. Fallback cost: not needed

Items 1 and 2 pass, so the native `Bitmap.compress` fallback was not prototyped.

### 7. Five-sheet back-to-back run: pass on the emulator

Five sheets of 18 photos, each decoded, drawn, encoded and disposed in turn, with `ui.Image` and `Picture` disposed and the image cache cleared:

| Sheet | Total | of which decode | Size | RSS after |
|---|---|---|---|---|
| 1 | 239 ms | 155 ms | 375 KB | 248 MB |
| 2 | 238 ms | 154 ms | 375 KB | 245 MB |
| 3 | 236 ms | 152 ms | 375 KB | 245 MB |
| 4 | 236 ms | 151 ms | 375 KB | 245 MB |
| 5 | 243 ms | 159 ms | 375 KB | 245 MB |

- Per-sheet time and RSS are flat, so there is no growth between sheets. `imageCache.currentSizeBytes` stays 0.
- Host-side PSS peaked at 168 MB during the run and settled at 142 MB afterwards (idle before: 121 MB).
- Max UI-isolate event-loop gap was 12 ms against an 8 ms timer, so decode, `toImage` and encode did not block the UI isolate. Rendering a live UI was not tested (see limits).

### 8. Decode strategy: prefer (b), target-size decode; memory not conclusive

(a) decode at full 1600 px, draw scaled, versus (b) `instantiateImageCodec(targetWidth: 343)`. Each mode ran for 5 sheet-sized batches in a **fresh process** to avoid order effects. A first in-process run showed that PSS is reclaimed lazily (121 → 468 MB across phases, then back to 157 MB), which made any peak comparison meaningless.

| Mode | Decode time, 18 photos | PSS idle → peak (delta) |
|---|---|---|
| (a) full, all at once | about 273 ms | 121 → 188 MB (+67) |
| (a) full, sequential | about 273 ms | 121 → 180 MB (+59) |
| (b) target, all at once | about 155 ms | 123 → 215 MB (+93) |
| (b) target, sequential | about 155 ms | 121 → 176 MB (+55) |

- **Speed:** (b) is clearly faster, about 1.75×.
- **Memory:** the deltas are within noise. The expected naive all-at-once cost (18 × 7.7 MB, about 138 MB) was **not observed** for (a), so the emulator hides most image memory (likely GPU-side). These numbers cannot decide between the strategies.
- **Tentative choice:** (b) with sequential decode, draw, dispose. It is the fastest, and had the lowest measured delta. Confirm on a real device with `dumpsys meminfo` Graphics and Native Heap lines before relying on it. A low-RAM device is not required.
- The multi-sheet run in item 7 used `targetWidth: 686` (2× the cell width). The visual effect of target-size decode on quality was not compared against (a).

### 9. Physical print and measure: not done

Needs a printer, its app and a ruler. Nothing is recorded for #2 yet. Procedure is in the issue.

## Conclusion

**Provisional go** on the Dart encoder and the DPI approach, pending a run on a real device:

1. Encode in a background isolate with `image` works. Encode is about 72 ms on the emulator.
2. DPI **requires a post-encode patch** of the JFIF APP0 bytes (the encoder writes unit 0, 1:1). Also write EXIF `XResolution`, `YResolution` and `ResolutionUnit` as `[dpi, 1]` lists. Verified on macOS only.
3. Draw with `FilterQuality.medium`.
4. Paint an opaque white background first.
5. Decode with `targetWidth` and handle photos one at a time (tentative).
6. The shared painter gives geometry parity, so keep it in sheet space and scale only for the preview.

## Not verified (blocks closing #1)

- [ ] Timing and peak memory on a real device, ideally the Galaxy S26 (items 1, 7, 8). No mid-range or low-RAM device needed.
- [ ] Real 1600 px photos, including EXIF orientation (items 3, 8)
- [ ] DPI read back in the Android gallery and the printer app's print flow (item 2)
- [ ] Live-UI jank during export, with frames being drawn (item 7)
- [ ] Item 9, physical print and measurement, and the hand-off to #2

## Follow-ups

- Doc cleanup from the issue (`layout_core` → `sheet_engine` in ADR-0001:50, the isolate claim at ADR-0001:14, geometry-not-pixel parity wording) is separate and not blocked by this.
- Once the open items are done, amend ADR-0001 with a link to this document and the pinned `image` version. Use a superseding ADR instead if the device run contradicts the above.

## Reproduce

```
cd spike
flutter run --profile -d <device>
adb logcat -d | grep SPIKE
adb pull /sdcard/Android/data/dev.snapcell.spike.jpeg_spike/files/ out/
```

For one decode mode in a fresh process, push a `mode.txt` (`a_full_allAtOnce`, `a_full_sequential`, `b_target_allAtOnce` or `b_target_sequential`) to that files directory before launching.
