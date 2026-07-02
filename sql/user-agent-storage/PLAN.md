# Keeping User-Agent data in tbl_bi_clicks (MS SQL Server) — Implementation Plan

## Summary

Store the raw HTTP User-Agent string associated with each click, without
bloating `tbl_bi_clicks` with a repeated `VARCHAR(512)` value on every row.
De-duplicate User-Agent strings into a new lookup table
(`tbl_user_agents`) and store only the two resulting surrogate IDs on
`tbl_bi_clicks`:

- `request_ua_id` — resolved from the server/request-side User-Agent (`@request_ua`)
- `click_ua_id` — resolved from the browser/click-side User-Agent (`@click_ua`)

The approach mirrors the existing `sub_id` / `tbl_websites_subid`
"get-or-create" pattern already used in `dbo.bi_click_insert_internal_v4`:
look up the value, and if it doesn't exist yet, insert it and handle the
concurrency race with a TRY/CATCH re-lookup.

## Why this design

- `tbl_bi_clicks` is a very high-volume, append-mostly table. Storing a
  512-byte string twice per row (request + click UA) would meaningfully
  increase row size and I/O; most UA values repeat across many clicks, so
  an `INT` surrogate key is far cheaper.
- The dedup-table + get-or-create pattern is already proven in this
  codebase for `sub_id_string`, so reviewers/DBAs already understand its
  failure modes.
- Surrogate keys also make large analytical queries **cheaper**:
  aggregations `GROUP BY` a 4-byte `int` instead of a 512-byte string, and
  `ua_id → user_agent` resolution is a hash join whose build side
  (`tbl_user_agents`) is small and buffer-pool-resident.

## Files (apply in order)

| # | File | What it does |
|---|------|--------------|
| 01 | `01_create_tbl_user_agents.sql` | Create the dedup lookup table |
| 02 | `02_alter_tbl_bi_clicks.sql` | Add `request_ua_id`, `click_ua_id` columns |
| 03 | `03_bi_click_insert_internal_v5.sql` | Internal insert proc with UA get-or-create |
| 04 | `04_bi_click_insert_v5.sql` | Public wrapper proc that calls the internal v5 |

## Schema changes

### 1. New table: `dbo.tbl_user_agents` (Design A)

```
ua_id              INT IDENTITY(1,1)  -> CLUSTERED PRIMARY KEY
user_agent         VARCHAR(512) COLLATE Latin1_General_CI_AS
                                      -> UNIQUE NONCLUSTERED index
creation_date_time DATETIME NULL      -> "first seen" timestamp
```

**Index design decision (Design A):** clustered PK on the `ua_id`
IDENTITY, unique **nonclustered** index on `user_agent`. This deliberately
*differs* from `tbl_websites_subid` (which clusters on the value), for a
specific reason:

- `tbl_websites_subid` clusters on `(website_id, sub_id_string)` — it has a
  **leading low-cardinality `int`** that gives insert locality and bounds
  the key space. Our table would have a **lone `varchar(512)` clustered
  key with no leading column**, so new UA strings would insert at random
  positions across the whole B-tree, splitting the clustered (data) pages
  on the hot insert path.
- UA strings churn continuously — bots/scrapers/spoofed traffic keep
  introducing new strings, so inserts never fully stop. An **append-only
  IDENTITY clustered key** avoids data-row page splits entirely; only the
  smaller nonclustered value index fragments, and it is cheap to
  `REORGANIZE`/`REBUILD` without moving table data.
- Both access patterns stay fast: `user_agent → ua_id` (insert hot path)
  is a covering seek on the unique nonclustered index (it carries `ua_id`);
  `ua_id → user_agent` (analytics joins) is a clustered seek.

**Collation `Latin1_General_CI_AS`:** matches the database default (and
`tbl_websites_subid.sub_id_string`), keeping `user_agent` consistent with
the rest of the schema and avoiding "cannot resolve collation conflict"
errors when it is joined/compared against other columns in ad-hoc
analytics. Dedup is therefore case-insensitive, which is rarely material
for real UA strings (a case-only variant is unusual and typically junk
traffic).

**`DATA_COMPRESSION = PAGE`:** UA strings share large boilerplate prefixes,
so page compression shrinks the table and keeps more of it cached.

**No `FOREIGN KEY`** from `tbl_bi_clicks` to this table — consistent with
how `sub_id` on `tbl_bi_clicks` is not FK-constrained to
`tbl_websites_subid`. On this hot insert path we skip the per-row FK check;
integrity is guaranteed by the proc's get-or-create logic.

File: `01_create_tbl_user_agents.sql`

### 2. Alter `dbo.tbl_bi_clicks`

```sql
ALTER TABLE dbo.tbl_bi_clicks ADD request_ua_id INT NULL;
ALTER TABLE dbo.tbl_bi_clicks ADD click_ua_id INT NULL;
```

Both nullable — a metadata-only change (no table rewrite), and consistent
with the fact that a UA string won't always be available (same reasoning
as the existing nullable `visitor_ip`/`request_ip`/`referrer` columns).

File: `02_alter_tbl_bi_clicks.sql`

### 3. New internal proc: `dbo.bi_click_insert_internal_v5`

Cloned from `v4`, adding:

- Two new nullable input parameters after `@request_id`:
  `@request_ua VARCHAR(512) = NULL`, `@click_ua VARCHAR(512) = NULL`.
- Two new locals: `@v_request_ua_id INT`, `@v_click_ua_id INT`.
- Defensive truncation mirroring the `visitor_ip`/`request_ip` handling
  (trim to 507 + `'...'`) so an over-long UA can never fail the insert.
- Two get-or-create blocks after the existing `sub_id` block, each with the
  same shape: lookup → `BEGIN TRY` insert + `SCOPE_IDENTITY()` →
  `BEGIN CATCH` re-select (handles the concurrent-insert unique-violation
  race, exactly like the `sub_id` block). New UA rows are inserted with
  `creation_date_time = GETDATE()`.
- **Empty-string handling:** guards use `NULLIF(@ua,'') IS NOT NULL`, so an
  empty-string UA is treated as "no UA" (id left NULL) rather than creating
  a junk empty-string row.
- **No `click_ua = request_ua` shortcut:** the `click_ua` block always does
  the lookup. A variable-to-variable comparison resolves in the *database
  default* collation, which is not guaranteed to match the `user_agent`
  column's collation (and would silently assign a wrong `ua_id` if they
  ever diverged). The lookup predicate (`WHERE user_agent = @click_ua`)
  resolves in the *column's* collation and is therefore correct by
  construction under any collation. The saved lookup was one seek on a
  small, cached table — not worth the fragility.
- `INSERT INTO dbo.tbl_bi_clicks` extended with `request_ua_id,
  click_ua_id` / `@v_request_ua_id, @v_click_ua_id`.

**Best-effort capture:** the CATCH re-selects rather than re-throwing, so a
UA-capture failure can never fail the click insert (worst case `ua_id`
stays NULL). This matches the `sub_id` behavior and is the right priority
for a non-critical field.

File: `03_bi_click_insert_internal_v5.sql`

### 4. New wrapper proc: `dbo.bi_click_insert_v5`

Clone of `bi_click_insert_v4` (the public entry point) with the same two
new `@request_ua`/`@click_ua` params, passed straight through to
`bi_click_insert_internal_v5`. Everything else (result set, campaign
lookup) is unchanged.

File: `04_bi_click_insert_v5.sql`

**Versioning:** shipped as `v5` (both procs) rather than mutating `v4` in
place, so any caller pinned to `v4` keeps working unchanged during rollout.

**Out of scope:** `bi_click_insert_invalid_v4` (banned-IP / duplicate-click
path) is not touched — invalid/banned clicks won't get
`request_ua_id`/`click_ua_id` unless a follow-up task extends that proc.

## Prerequisites / environment

- `DATA_COMPRESSION = PAGE` requires SQL Server 2016 SP1+ (any edition; it
  was Enterprise-only before that).
- `OPTIMIZE_FOR_SEQUENTIAL_KEY = ON` on the clustered PK requires SQL Server
  2019+. On older versions, remove that option (harmless to drop).

## Rollout steps

1. Deploy `01` (new table — zero risk, no existing readers/writers).
2. Deploy `02` (`ADD` two nullable INT columns — metadata-only, no rewrite).
3. Deploy `03` then `04` (`CREATE OR ALTER`, safe to run repeatedly).
4. Update the calling application/API layer to:
   - Call `bi_click_insert_v5` instead of `v4`.
   - Pass the server-side UA header as `@request_ua` and the
     browser-reported UA (if collected separately) as `@click_ua`. If only
     one is available, pass it and leave the other NULL.
5. Leave `v4` (wrapper + internal) in place until all callers have
   migrated, then remove in a later cleanup task.

## Testing / acceptance criteria

- [ ] `tbl_user_agents` created: clustered PK on `ua_id`, unique
      nonclustered `CI_AS` index on `user_agent`, PAGE compression.
- [ ] `tbl_bi_clicks` has new nullable `request_ua_id`, `click_ua_id`.
- [ ] New UA string → new row in `tbl_user_agents` (with
      `creation_date_time` set) and its `ua_id` stored on the click row.
- [ ] Same UA string again → no duplicate row; existing `ua_id` reused.
- [ ] `@request_ua`/`@click_ua` NULL **or empty string** → id left NULL, no
      junk `''` row created.
- [ ] Case-insensitive dedup: two UAs differing only in case collapse to a
      single row (CI_AS).
- [ ] Concurrency: many parallel inserts of the same brand-new UA produce
      exactly one row, and no proc call fails.
- [ ] Existing `v4` callers unaffected.
- [ ] No measurable regression in insert latency/throughput on
      `tbl_bi_clicks` under load.

## Risks / considerations

- **Race on first insert of a new UA** — handled via TRY/CATCH + re-select,
  identical to the existing `sub_id` pattern.
- **Index key size** — `VARCHAR(512)` single-byte = 512 bytes, under SQL
  Server's 900-byte nonclustered-index key limit.
- **Hot-path performance** — up to 2 extra lookups per click insert, each a
  seek on the small, cached `tbl_user_agents`; comparable to the existing
  `sub_id` lookup.
- **Unbounded growth of `tbl_user_agents`** — UA strings have a long,
  continuously-growing tail (bots/spoofing), so plan for ongoing (not
  saturating) inserts. Growth is still modest vs. `tbl_bi_clicks`; monitor
  row count post-launch. PAGE compression mitigates size.
- **No FK enforcement** — intentional, matches `sub_id`; flag to reviewers
  as a deliberate deviation from "always add the FK."

## Suggested Jira breakdown

See `JIRA_TASK.md` for copy/paste-ready ticket content. Subtasks:

1. **[DB] Create `tbl_user_agents` table** (`01`).
2. **[DB] Alter `tbl_bi_clicks`: add `request_ua_id`, `click_ua_id`** (`02`).
3. **[DB] Create `bi_click_insert_internal_v5`** (`03`).
4. **[DB] Create `bi_click_insert_v5` wrapper** (`04`).
5. **[App/API] Switch click-insert call site(s) to `v5`**, wire up
   `@request_ua` / `@click_ua`.
6. **[QA] Concurrency + acceptance test pass** per checklist above.
7. **[Ops] Rollout + monitor** `tbl_user_agents` growth and
   `tbl_bi_clicks` insert latency; keep `v4` as fallback until migrated.
8. *(Follow-up, optional)* Extend `bi_click_insert_invalid_v4` similarly.
