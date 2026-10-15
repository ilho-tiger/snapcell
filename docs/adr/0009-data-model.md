# ADR-0009: Data model — drift schema

- Status: Proposed
- Date: 2026-10-15
- Builds on: ADR-0002 (drift), ADR-0004 (photo files), ADR-0006 (job tables)
- Supersedes: the phrase "a favorite flag" in ADR-0002 (favorites are a table, below)
- Amended by: [ADR-0008](0008-generation-state-machine-and-output-lifecycle.md) (adds `generation_job.failure`)

## Context

The data model is spread across ADR-0002 (relational shape in prose), ADR-0004 (photo columns), ADR-0006 (job tables) and requirements FR-1.x and §4. This ADR gives one schema for drift. Rules that shape it:

- Dates are date-only values with the full year (FR-1.7).
- A date has zero or more candidates (FR-1.2) and at most one favorite (FR-1.4).
- A photo belongs to exactly one date and has its own file and comment (FR-1.3, ADR-0004).
- A single global configuration (§4). Limits are validated by `sheet_engine`, not the database (ADR-0003).

## Decision

### Conventions

- **Dates** are `TEXT` in ISO `YYYY-MM-DD`. They sort correctly as text, and no time or timezone exists to shift them. drift maps them to a small `DiaryDate` value type, never to `DateTime`.
- **Ids** are app-generated UUID `TEXT` for photos and jobs (ADR-0004: the id is known before the file is written).
- **Timestamps** (`created_at`) are `INTEGER` epoch milliseconds, UTC. They only order rows and are never shown as diary dates.
- **Lengths** are `REAL` millimetres. Paper in inches (4 × 5.5) is converted at the UI edge.
- **Foreign keys** are enforced: `PRAGMA foreign_keys = ON` in drift's `beforeOpen`, since SQLite defaults to off. WAL mode is on (ADR-0006).

### Tables

**`photo`**: one stored candidate.

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | UUID |
| `diary_date` | TEXT NOT NULL | Index. The date the user assigned |
| `file_path` | TEXT NOT NULL | Relative to the files directory, e.g. `photos/<id>.jpg` (ADR-0004) |
| `capture_date` | TEXT NULL | EXIF `DateTimeOriginal`, date-only, metadata only (FR-1.7) |
| `comment` | TEXT NOT NULL DEFAULT '' | Not printed (FR-1.5) |
| `created_at` | INTEGER NOT NULL | Candidate display order is `created_at`, then `id` (reordering is out of scope) |

**`favorite`**: the chosen candidate for a date.

| Column | Type | Notes |
|---|---|---|
| `diary_date` | TEXT PK | At most one favorite per date, enforced by the key |
| `photo_id` | TEXT NOT NULL UNIQUE | FK → `photo.id`, `ON DELETE CASCADE` |

Removing the favorite photo clears the favorite by itself. The date then has no favorite and the generation flow asks again (FR-2.2). The repository must check that the photo's `diary_date` equals the favorite's `diary_date`, because SQLite cannot express that cross-row rule without a composite key. A composite key `(photo.id, photo.diary_date)` is not worth the extra schema here.

**Effective photo for a date** (read by the render plan): the favorite if present, else the only candidate if there is exactly one, else unresolved. No date row exists. A date exists only through its photos.

**`app_config`**: one row, `id INTEGER PK CHECK (id = 1)`.

| Column | Default |
|---|---|
| `paper_w_mm`, `paper_h_mm` | 101.6, 139.7 |
| `cell_w_mm`, `cell_h_mm` | 30, 20 |
| `inset_mm` | 0.5 |
| `spacing_mm` | 2 |
| `margin_top_mm`, `margin_bottom_mm`, `margin_left_mm`, `margin_right_mm` | 3 each |
| `orientation` (`portrait`, `landscape`) | `portrait` |
| `cut_guides` | 1 |
| `dpi` | 300 |
| `date_labels` | 1 |
| `label_format` | `MMM/d` |
| `label_height_mm` | 3 |

The row is created lazily on first save. When it is absent, `sheet_engine` supplies the defaults, so defaults live in one place. Values are stored as the user entered them. Invalid values are rejected at generation time with all errors reported (FR-6.9), not by database constraints.

**`generation_job`** and **`generation_sheet`** follow ADR-0006, with ADR-0008's addition:

| Table | Columns |
|---|---|
| `generation_job` | `id` TEXT PK, `state`, `range_start`, `range_end`, `config_snapshot` (JSON), `render_plan` (JSON), `failure` (JSON, nullable), `created_at` |
| `generation_sheet` | `job_id` FK → `generation_job.id` `ON DELETE CASCADE`, `sheet_index`, `status`, `saved_uri` NULL, `error` NULL. PK `(job_id, sheet_index)` |

- `state` ∈ `rendering`, `ready`, `saving`, `failed`. `status` ∈ `pending`, `rendered`, `saved`, `failed`. `failure` holds `{kind: photos_missing | save_failed, dates: [...]}`.
- `config_snapshot` is the engine's serialized config. `render_plan` is `{sheets: [[{date, photoId}, ...], ...]}`. Both carry a `v` field so a later app version can read or reject an old job.
- The plan stores photo ids, not paths, and has **no foreign key** to `photo`. A resume looks each id up and fails the job if a photo is gone (FR-2.14). A foreign key would instead block photo removal or cascade into the plan.
- Skipped dates (FR-2.5) are not stored. They are the range minus the dates present in the plan.
- At most one job exists, enforced in the repository's transaction (ADR-0006).

### Ownership

- `PhotoRepository`: `photo`, `favorite`. `ConfigRepository`: `app_config`. `GenerationJobRepository`: the two job tables. Repositories are interfaces over drift (ADR-0002) and are tested with an in-memory database under `dart test`.
- Files stay out of the schema except for paths. Write order and the startup sweep follow ADR-0004.

### Migrations

Start at `schemaVersion` 1. Use drift's schema dump and generated migration tests (ADR-0002) from the first release, so each later change is verified against the dumped schema.

## Consequences

- Two lookups (`photo` by date, `favorite` by date) answer every question the generation flow asks. One index on `photo.diary_date` is enough at diary scale (hundreds to low thousands of rows).
- Favorites cannot dangle: the cascade removes them with their photo.
- A `favorite` row whose photo sits on another date is possible if the repository is bypassed. Repository tests must cover it.
- `app_config` and the job's `config_snapshot` share one serialized form from `sheet_engine`, so the engine owns the config shape and the app owns only storage.
- JSON columns are not queryable. That is acceptable because job data is read whole, and there is at most one job.
- `DiaryDate` as a distinct type, rather than a `String` or `DateTime`, makes FR-1.7 a compile-time property.

## Rejected alternatives

- **`is_favorite` flag on `photo`.** Needs a partial unique index, which drift does not declare natively (a hand-written migration statement), and "no favorite" has no explicit state to check.
- **A `diary_day` table.** Dates carry no data of their own in v1. An extra table needs row upkeep and invites rows with no photos.
- **Config as one JSON column.** Hides settings from drift's typed queries and from schema migrations, for a table that holds one row.
- **Storing dates as epoch days.** Compact, but unreadable in the database and in logs, with no benefit at this scale.

## Related

- ADR-0002: State management and persistence (Riverpod + drift)
- ADR-0003: Monorepo package layout (`sheet_engine`)
- ADR-0004: Photo storage — copy in, downscaled
- ADR-0006: Background sheet generation
- ADR-0008: Generation state machine and render-output lifecycle
