# Spike 001: Flutter JPEG export pipeline

- Issue: [#1](https://github.com/ilho-tiger/snapcell/issues/1)
- Date: 2026-10-16
- Verifies: [ADR-0001](../adr/0001-application-framework.md) (shared painter, encode, DPI), with input for [ADR-0004](../adr/0004-photo-storage.md)
- Code: directory `spike/` on branch `spike/jpeg-export`, commit `8e626eb` (throwaway, never merged to `main`; keep the branch so the numbers stay reproducible)
- Status: **done. Decision: go.** Items 1–8 were measured on the target device. Item 9 (physical print) is out of scope, see item 9. ADR-0001 is updated accordingly.

## Question

Can `CustomPainter` → `PictureRecorder` → `Picture.toImage` → RGBA → JPEG in an `Isolate` produce a correct 1200 × 1650 sheet with declared DPI (FR-6.4), at acceptable speed and quality?

## Method and setup

A Flutter app (`spike/lib/main.dart`) runs the whole pipeline on startup and logs `SPIKE ...` lines to logcat. Sample outputs were pulled with `adb pull` and read back on the Mac with `sips` and a small Python JFIF/EXIF parser. Memory comes from host-side `adb shell dumpsys meminfo` (PSS and Graphics) sampled about every 0.3 s.

| | Real device (primary) | Emulator (earlier run) |
|---|---|---|
| Target | `SM-S931U1` (product `pa1quew`), Snapdragon 8 Elite (SM8750), 11 GB RAM, Android 17 (API 37), arm64, over wireless debugging | AVD `snapcell_pixel`, Android 16 (API 36), 2 GB RAM, software GPU, on an Apple M5 Pro host |
| Input photos | 18 real camera JPEGs picked evenly across the file-size range of 206 in `DCIM/Camera` (12 MP, 4000 × 3000 or 3000 × 4000, 1.9–7.5 MB each) | 18 synthetic 1600 × 1200 JPEGs |
| Build | `--profile`, Flutter 3.47.7, Impeller, `image` 4.12.0 | same |

**Device.** The target device is a Galaxy S25. The test device is a Galaxy S25 (`SM-S931U1`, US unlocked), so results apply directly. A mid-range or low-RAM device is not a target.

Painter: one `SheetPainter` that draws in 1200 × 1650 sheet space only: opaque white background, 3 × 6 cells of 343 × 224 px (cover crop), a label above each cell.

Photo import is done as setup, the way ADR-0004 describes it: decode, bake EXIF orientation, cap the long edge at 1600 px, re-encode at quality 85. The pipeline then runs on those stored copies, not on the originals.

### Limits

- 18 photos from one phone, with no printing step. Photo content is personal, so the outputs were **not** committed and are not reproduced here.
- None of the 18 photos carried an EXIF orientation tag (the camera writes the pixels already rotated, e.g. 3000 × 4000 portrait). The orientation-baking path ran but was not exercised.
- Frame timings were taken with a spinner animating. The device refresh rate was not recorded. If it is 120 Hz, the budget is 8.3 ms and the 16.7 ms counts below are the lenient reading.
- Memory sampling at 0.3 s over Wi-Fi is coarse. PSS is reclaimed lazily, so peaks across back-to-back phases are order-dependent; the decode comparison therefore uses one fresh process per mode.

## Results (real device)

### 1. Encode quality and speed: pass

The pure-Dart `image` encoder in `Isolate.run`, with the RGBA bytes passed as `TransferableTypedData`, produced a valid 1200 × 1650 JPEG (quality 92).

| Step (one sheet, 18 real photos) | Time |
|---|---|
| `Picture.toImage` | 45 ms |
| `toByteData(rawRgba)` | 25 ms |
| JPEG encode in isolate | 235 ms |
| Output size | 734 KB |

About 0.3 s for the render and encode of one sheet. On the emulator the encode took 72 ms, so the real device is about 3× slower than the Mac-hosted emulator.

### 2. DPI: pass, but the encoder does not do it by itself

- `image` 4.12.0 always writes a JFIF APP0 segment with **unit = 0, density 1:1** (aspect ratio only). The default output declares no DPI. See `jpeg_encoder.dart:687-700` in the package.
- Patching APP0 after encoding works: set byte 13 (unit) to 1 and bytes 14–17 to 300 (big-endian). Verified on the device's output: `sips` reports 300 × 300 DPI at 1200 × 1650.
- EXIF `XResolution`, `YResolution` (300/1) and `ResolutionUnit` (2 = inch) can be written through `image.exif.imageIfd`. Pitfall: the setters take a `Rational` or a `[numerator, denominator]` list. Passing an `IfdValueRational` is **silently dropped**. Verified by parsing IFD0 of an output file.
- macOS `sips` reads 300 DPI from either tag alone (JFIF-only and EXIF-only copies both report 300). With neither, it reports 72.
- Not checked: DPI read back in an Android gallery app (see Not verified). The printer app's print flow is out of scope (item 9).

### 3. Downscale quality: `medium` is fine, and the choice matters little for photos

Cell 0 was rendered at each `FilterQuality` and compared with a box-filter (average) reference using mean absolute error over RGB (0–255).

| FilterQuality | Real photo MAE | Synthetic stress test MAE |
|---|---|---|
| `none` | 11.17 | 16.77 (strong aliasing) |
| `low` | 10.58 | 13.02 (visible moiré) |
| `medium` | 10.58 | 7.57 (clean) |
| `high` | 10.58 | 7.57 (identical to `medium`) |

- On real photos, `low`, `medium` and `high` come out identical and only `none` is worse. The synthetic image (2 px checker, 1 px lines) is the case where `low` fails. Images from the synthetic run are in `001-jpeg-export/` (`cell_none.png`, `cell_low.png`, `cell_medium.png`, `cell_reference.png`).
- The absolute real-photo MAE (about 10.6) is higher than the synthetic one even for the best filter. A likely cause is sub-pixel misregistration between the mip-chain result and the reference crop on detailed photo content, not aliasing, but I did not verify that. **The real-photo cells were not inspected visually** (private content). A visual check was not done.
- Use `FilterQuality.medium`. It costs nothing over `low` and is safe on fine patterns.

### 4. Preview and export parity: geometry passes

- The painter draws only in sheet space. The preview applies `canvas.scale(0.3)`. A 0.3× preview compared with the export downscaled by a box filter gives MAE 6.05 on real photos (1.79 on synthetic). Cell and label positions are identical by construction.
- Label layout is computed in sheet space (113.8 × 28.0 px for the test label), so it does not depend on preview scale.
- The real-photo MAE is higher, most likely because of photo detail resampled two different ways, not because of layout. This supports the ADR-0001 follow-up wording: the shared painter guarantees **geometry** parity, not pixel parity.

### 5. Alpha: pass

After the opaque white first fill, the minimum alpha over all 1200 × 1650 pixels is 255. The JPEG has no alpha artifacts.

### 6. Fallback cost: not needed

Items 1 and 2 pass, so the native `Bitmap.compress` fallback was not prototyped.

### 7. Five-sheet back-to-back run: pass, with small frame hitches

Five sheets of 18 photos, each decoded, drawn, encoded and disposed in turn, with `ui.Image` and `Picture` disposed and the image cache cleared. A spinner was animating throughout.

| Sheet | Total | of which decode | Size |
|---|---|---|---|
| 1 | 713 ms | 467 ms | 688 KB |
| 2 | 704 ms | 465 ms | 686 KB |
| 3 | 692 ms | 455 ms | 684 KB |
| 4 | 693 ms | 454 ms | 688 KB |
| 5 | 749 ms | 455 ms | 688 KB |

- **Time is flat across sheets, and memory returns to baseline.** `imageCache.currentSizeBytes` stays 0. After the run, PSS settled at 133 MB, below the 137 MB idle before the first phase. (The peak during the run, 298 MB with 179 MB Graphics, still carries residue from the preceding phase, so it is an upper bound and not a clean figure. Item 8 has the clean per-strategy peaks.)
- **UI frames during the run** (559 frames): p50 1.5 ms, p99 17.0 ms, **max 86.0 ms**, 6 frames over 16.7 ms, **2 frames over 33 ms**. The UI isolate event-loop gap, measured with an 8 ms timer, peaked at 20 ms.
- Interpretation: the animation stays smooth almost all the time, but there are occasional hitches of 2–5 frames while the work runs on the UI isolate (`toImage` and decode run there, only the encode is off it). That is two bad frames across five sheets. This is acceptable for a foreground progress screen. Under ADR-0006 the job runs in a foreground-service isolate with no UI, so it matters only if generation runs while the user is looking at an animating screen.

### 8. Decode strategy: (b) target-size, one photo at a time

(a) decode at full stored size (1600 px long edge), draw scaled, versus (b) `instantiateImageCodec(targetWidth: 343)`. Each mode ran 5 sheet-sized batches in a **fresh process**.

| Mode | Decode time, 18 photos | PSS idle → peak (delta) | Graphics peak |
|---|---|---|---|
| (a) full, all at once | about 1.14 s | 138 → 363 MB (+226) | 199 MB |
| (a) full, sequential | about 1.13 s | 138 → 186 MB (+48) | 21 MB |
| (b) target, all at once | about 0.23 s | 137 → 196 MB (+59) | 28 MB |
| (b) target, sequential | about 0.22 s | 137 → 178 MB (+40) | 10 MB |

- **Speed:** (b) is about 5× faster, about 12 ms per photo against 63 ms.
- **Memory:** the naive all-at-once full decode (a) is the outlier, at +226 MB, in line with the 18 × 7.7 MB (about 138 MB) estimate plus overhead. Decoding one at a time takes it from +226 MB to +48 MB, and (b) brings the peak to +40–59 MB.
- **Choice:** (b) with sequential decode, draw, dispose.
- The multi-sheet run in item 7 decoded 18 photos at once at `targetWidth: 686` (2× the cell width). Switching it to sequential would lower its peak further. The quality effect of target-size decode against (a) was not compared visually.

### 9. Physical print and measure: out of scope

Not done, and not going to be. How a photo printer app scales or crops the file, and whether it honors the DPI tag, is the printer app's responsibility. The app only produces the print-ready file (FR-6.8). The spike checks that the file declares 300 DPI correctly, which it does.

### Related import measurements (setup step, input for ADR-0004 and #3)

Importing the 18 photos (decode, bake orientation, downscale to 1600 px, re-encode at quality 85) in a pure-Dart isolate took 520–1034 ms per photo, 14.6 s for all 18, with no out-of-memory. Output size was 217–496 KB per photo, mean 339 KB, which fits the ADR-0004 estimate of 300–500 KB. Later photos took about 1.0 s each against about 0.55 s for the first ones; the cause was not investigated. This is not the #3 comparison (no native `maxWidth` run), but it shows the pure-Dart downscale is workable at about 1 s per photo.

## Emulator run (earlier, synthetic photos)

Kept for context. The emulator gave unusable memory numbers (GPU memory is hidden, so no per-strategy difference showed up), which is why the real-device run replaces it for item 8. It found the two DPI pitfalls in item 2 and produced the synthetic filter comparison in item 3.

| | Emulator |
|---|---|
| Encode in isolate | 72 ms |
| `toByteData` | 18 ms (105 ms cold) |
| 5 sheets, per sheet | about 240 ms, flat |
| Decode, 18 photos, (a) vs (b) | about 273 ms vs 155 ms |
| UI event-loop gap | 12 ms max |

## Conclusion

**Go** on the Dart encoder and the DPI approach.

1. Encode in a background isolate with `image` works. About 0.3 s per sheet on the device, about 0.7 s per sheet including decode.
2. DPI **requires a post-encode patch** of the JFIF APP0 bytes (the encoder writes unit 0, 1:1). Also write EXIF `XResolution`, `YResolution` and `ResolutionUnit` as `[dpi, 1]` lists. Verified on macOS only.
3. Draw with `FilterQuality.medium`.
4. Paint an opaque white background first.
5. Decode with `targetWidth`, one photo at a time. This cuts decode time about 5× and peak memory from +226 MB to about +40 MB.
6. The shared painter gives geometry parity, so keep it in sheet space and scale only for the preview.
7. Expect occasional frame hitches if generation runs on the UI isolate while an animation is on screen. A 5-sheet job takes about 3.5 s.

## Not verified (not blocking)

- [ ] DPI read back in the Android gallery (item 2)
- [ ] Visual check of real-photo cells and parity (items 3, 4)
- [ ] A photo that actually has an EXIF orientation tag (none of the 18 did)

## Follow-ups

- ADR-0004: the downscale is about 1 s per 12 MP photo in a pure-Dart isolate on this device. Whether native `maxWidth` replaces it is the #3 question.

## Reproduce

Check out `spike/jpeg-export` at `8e626eb` first.

```
cd spike
flutter run --profile -d <device>
adb logcat -d | grep SPIKE
adb pull /sdcard/Android/data/dev.snapcell.spike.jpeg_spike/files/ out/
```

To use real photos, copy JPEGs into `<files dir>/photos/` on the device before launching. Without a `photos/` directory the app generates synthetic photos. For one decode mode in a fresh process, push a `mode.txt` (`a_full_allAtOnce`, `a_full_sequential`, `b_target_allAtOnce` or `b_target_sequential`) to the files directory before launching.
