# Snapcell (하루칸) — Business Requirements (v1)

## 1. Overview

### 1.1 Purpose
**Snapcell** (Korean: **하루칸**, Harukan) is a phone app for users who keep an analog, calendar-based diary whose day cells are small (default 30 mm × 20 mm). The application lets a user pick phone photos for diary dates and generate print-ready photo sheets. The user prints the sheets on a photo printer, cuts the photos out, and pastes them into the diary cells.

### 1.2 Core scenario
- **Given** an analog calendar diary with day cells of 30 mm × 20 mm
- **When** the user associates one or more phone photos with diary dates and selects a date range
- **Then** the app creates one or more grid sheets sized for 4 in × 5.5 in photo paper
- **So that** the user can print, cut, and paste the photos into the diary.

### 1.3 Goals
- Work on a phone alone, with no computer needed. Android first, iPhone later.
- Minimum supported Android version is 16 (API 36). See [ADR-0005](adr/0005-photo-picker-and-gallery-save.md).
- Support different photo paper sizes and diary cell sizes through configuration.

### 1.4 Glossary

| Term | Meaning |
|---|---|
| Snapcell / 하루칸 | The application name (English / Korean). "하루" = a day, "칸" = a cell. |
| Cell | A diary day cell (default 30 × 20 mm). |
| Photo rectangle | The printed photo area: `cell size − 2 × inset` (default 29 × 19 mm). |
| Label cell | Optional small cell above the photo rectangle that holds the date label. |
| Unit | Label cell + photo rectangle, treated as one item when packing. |
| Candidate | A photo associated with a date. A date may have several. |
| Favorite | The candidate chosen to be printed for a date. |
| Sheet | One generated JPEG sized to the paper. |

---

## 2. User stories

| ID | Story |
|---|---|
| US-1 | As a user, I want paper size and diary cell size to be configurable, so I can use the app with different photo printers and diaries. |
| US-2 | As a user, I want to use the app comfortably on a smartphone (Android first, iPhone later), so I can add photos, assign them to dates, and generate print-ready sheets without a computer. |
| US-3 | As a user, I want to assign several candidate photos to a diary date, whatever their capture date, and add a short comment to each, so I can decide later which one to print. |
| US-4 | As a user, I want to generate sheets for any date range, so I can print a month, a week, or any other span. |

---

## 3. Functional requirements

### 3.1 Photo and date management

| ID | Requirement |
|---|---|
| FR-1.1 | The user manually associates any photo with any diary date, regardless of the photo's capture date. |
| FR-1.2 | A date may have multiple candidate photos. |
| FR-1.3 | The same photo may be associated with several dates. |
| FR-1.4 | The user can set a favorite photo for a date while assigning photos, and can change it at any time. |
| FR-1.5 | The user can add a short comment to each photo. Comments are stored in the app only and are **not printed** in v1. |
| FR-1.6 | The user can remove a photo from a date or replace it. Reordering candidates is not supported. |
| FR-1.7 | Dates are stored with the full year, because a diary may span years. |

### 3.2 Generation flow

| ID | Requirement |
|---|---|
| FR-2.1 | The user selects any date range, not just a calendar month. |
| FR-2.2 | If a date has multiple candidates and no favorite, the app asks the user to choose one. The choice is saved as the favorite, so later generations reuse it without asking. |
| FR-2.3 | If any dates in the range have no photo, the app asks the user to confirm before continuing. |
| FR-2.4 | After confirmation, available photos are packed together with no blank cells for empty dates. |
| FR-2.5 | After confirmation, the app shows the list of skipped (empty) dates. |
| FR-2.6 | As many sheets as needed are generated to hold all selected photos. |
| FR-2.7 | Each range generation starts on a fresh sheet. A partly empty last row is acceptable. Dates outside the range are never used as filler. |
| FR-2.8 | Before saving, the app shows a read-only preview of the generated sheets. |
| FR-2.9 | Each generation produces new files. It never overwrites earlier output. |

### 3.3 Layout and packing

| ID | Requirement |
|---|---|
| FR-3.1 | Cells are placed in date order: left to right in rows, top to bottom, then continuing onto the next sheet. |
| FR-3.2 | Cells are **never rotated**. Every cell is landscape, matching the diary cell, whatever the photo's orientation. |
| FR-3.3 | Margins, spacing, and cut guides reduce the usable area. The app does not compensate for this. Fewer cells per sheet is acceptable, because more sheets are generated instead. |
| FR-3.4 | Default spacing between photos is about 2 mm (configurable). |
| FR-3.5 | Cut guides are drawn centered in the gap between photos. Cutting errors then land in white space, not on the image. |
| FR-3.6 | Default page orientation is portrait (configurable). |
| FR-3.7 | Printable margins are set per side (top, bottom, left, right), each defaulting to 3 mm and configurable. Spacing is also configurable (FR-3.4). |
| FR-3.9 | The grid of cells is centered within the area left after the margins. Leftover space is split evenly on opposite sides. |
| FR-3.8 | Cut guides are on by default (configurable). |

**Reference capacity** (4 × 5.5 in paper, 29 × 19 mm photos, 2 mm gaps, before printer margins): at most 18 cells in portrait (3 × 6) or 16 in landscape (4 × 4).

### 3.4 Date labels (optional)

| ID | Requirement |
|---|---|
| FR-4.1 | Date labels can be turned on or off. |
| FR-4.2 | The default format is month-text/day without the year (e.g. `Oct/15`). The format is configurable. |
| FR-4.3 | A label sits in its own small cell directly above the photo cell, outside the photo rectangle, so it never reduces photo height. |
| FR-4.4 | Label cell height is at most 3 mm (about 35 px at 300 DPI) and is configurable. |
| FR-4.5 | The packer treats label cell + photo cell as one unit. Enabling labels therefore reduces the number of units per sheet. |

### 3.5 Photo sizing and cropping

| ID | Requirement |
|---|---|
| FR-5.1 | Photo rectangle = `cell size − 2 × inset`. The default inset is 0.5 mm per side (29 × 19 mm for a 30 × 20 mm cell). An inset of 0 gives exact fit. The reason is that hand-cut photos are never exact, so the printed photo is slightly smaller than the diary cell. |
| FR-5.2 | The packer, crop target, and per-photo pixel size all use the photo rectangle size, not the cell size. |
| FR-5.3 | Phone photos are usually 4:3 or 3:4, and the cell aspect ratio is configurable, so a photo may not match the photo rectangle. When cropping is needed, the photo is scaled until it covers the rectangle ("zoom to fit") and cropped around its center. |
| FR-5.4 | Portrait photos are not rotated. They are cropped like any other mismatch. |
| FR-5.5 | There is no manual pan or zoom. |
| FR-5.6 | v1 supports crop (cover) only. A fit-without-cropping mode, with fill bars and a per-photo choice, is out of scope (§5). |

### 3.6 Output

| ID | Requirement |
|---|---|
| FR-6.1 | Output is JPEG, at a resolution high enough for photo printing. JPEG is used because photo printers usually don't support PDF but do support JPEG. |
| FR-6.2 | Output DPI defaults to 300 and is configurable. |
| FR-6.3 | Pixel size is derived, not set directly: `pixels = round(inches × DPI)` per side, swapped for orientation. Default: 4 × 5.5 in portrait at 300 DPI gives **1200 × 1650 px**. |
| FR-6.4 | The DPI value is written to the JPEG metadata to declare the physical size. |
| FR-6.5 | Each photo is cropped (if applicable) and then downscaled to its photo rectangle's pixel size. Default: about 343 × 224 px for 29 × 19 mm at 300 DPI. |
| FR-6.6 | File names include the date range and sheet number, e.g. `diary_2026-10-01_2026-10-18_p1.jpg`. |
| FR-6.7 | Output is saved to the phone gallery. |
| FR-6.8 | The app only produces the print-ready file. Direct printer support is out of scope. |

### 3.7 Localization

| ID | Requirement |
|---|---|
| FR-7.1 | The v1 UI is English only. |
| FR-7.2 | All user-facing text must be translatable later, with no hardcoded strings. |
| FR-7.3 | The application name is **Snapcell** in English and **하루칸** in Korean. The name is a translatable string like any other user-facing text, so the displayed name follows the UI language once Korean is added. |

---

## 4. Configuration

A single global configuration applies in v1.

| Setting | Default | Notes |
|---|---|---|
| Paper size | 4 × 5.5 in | Configurable |
| Diary cell size | 30 × 20 mm | Configurable |
| Photo inset per side | 0.5 mm | 0 = exact fit |
| Spacing between photos | ~2 mm | Configurable |
| Printable margins | 3 mm per side (top, bottom, left, right) | Configurable per side |
| Page orientation | Portrait | Configurable |
| Cut guides | On | Configurable |
| Output DPI | 300 | Configurable |
| Date labels | Off (default to be confirmed) | Optional |
| Label format | `Mon/D` (e.g. Oct/15) | Configurable |
| Label cell height | ≤ 3 mm | Configurable |

---

## 5. Out of scope (v1)

- Direct printing from the app.
- Printing comments.
- Multiple diaries or multiple configuration profiles.
- Overwriting old sheets, and tracking what has been printed.
- Using later dates as filler to complete a partly empty last row.
- Reordering candidate photos.
- Backup or export of associations, favorites, and comments. Uninstalling the app loses this data.
- Manual pan or zoom of photos.
- Fit-without-cropping mode (contain), including its fill colour and a per-photo crop/fit choice. v1 always crops (cover).
- UI languages other than English.
- iPhone support (Android first).

---

## 6. Open questions

| # | Question | Status | Resolution |
|---|---|---|---|
| OQ-1 | Implementation technology: Android native, Flutter, or PWA? | Resolved | Flutter. See [ADR-0001](adr/0001-application-framework.md). |
| OQ-2 | Are photos copied into the app, or only referenced? | Resolved | See [ADR-0004](adr/0004-photo-storage.md). Photos are copied into the app's private storage, downscaled to about 1600 px on the long edge at import. The printed photo is only about 343 × 224 px, so this is more than enough, and it removes the case of a referenced photo disappearing from the gallery. A very large cell or DPI setting could exceed the stored resolution; the stored size is capped. |

---

## 7. Gaps noted in the source (for confirmation)

- **Fit without cropping and default crop vs. fit (resolved):** v1 supports crop (cover) only (FR-5.6), so the fill colour and the default no longer arise. Portrait photos are cropped to the landscape cell (FR-5.4) and lose roughly half of their height.
- **Label default:** the source says labels are optional but not whether they are on by default. I assumed off.
- **Margin defaults and grid placement (resolved):** the source gave no values. v1 uses four per-side margins of 3 mm (FR-3.7), with the grid centered in the remaining area (FR-3.9). The 3 mm default is an estimate. It keeps the reference capacity (18 portrait, 16 landscape) but has not been checked against a real printer.
- **Missing photo at generation (resolved):** the source didn't say what happens if a referenced photo is gone when generating. Photos are now copied into the app at import (OQ-2, [ADR-0004](adr/0004-photo-storage.md)), so this case no longer exists.
