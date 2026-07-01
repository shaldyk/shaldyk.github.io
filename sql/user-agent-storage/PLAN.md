# User-Agent Storage for tbl_bi_clicks — Implementation Plan

## Summary

Store the raw HTTP User-Agent string associated with each click, without
bloating `tbl_bi_clicks` with a repeated `VARCHAR(512)` value on every row.
Instead, de-duplicate User-Agent strings into a new lookup table
(`tbl_user_agents`) and store only the two resulting surrogate IDs on
`tbl_bi_clicks`:

- `request_ua_id` — resolved from the server/request-side User-Agent (`@request_ua`)
- `click_ua_id` — resolved from the browser/click-side User-Agent (`@click_ua`)

The approach mirrors the existing `sub_id` / `tbl_websites_subid`
"get-or-create" pattern already used in
`dbo.bi_click_insert_internal_v4` (see lines 204-222 of the attached
script): look up the value, and if it doesn't exist yet, insert it and
handle the race with a TRY/CATCH re-lookup.

## Why this design

- `tbl_bi_clicks` is a very high-volume, append-mostly table. Storing a
  512-byte string twice per row (request + click UA) would meaningfully
  increase row size and I/O; most values repeat across many clicks
  (a given browser/bot sends the same UA string thousands of times), so an
  INT surrogate key is far cheaper.
- The pattern (dedup table + get-or-create lookup in the insert proc) is
  already proven in this codebase for `sub_id_string`, so reviewers/DBAs
  are already familiar with the trade-offs and failure modes.

## Schema changes

### 1. New table: `dbo.tbl_user_agents`

```sql
CREATE TABLE dbo.tbl_user_agents (
    ua_id       INT IDENTITY(1,1) NOT NULL,
    user_agent  VARCHAR(512)      NOT NULL,
    CONSTRAINT PK_tbl_user_agents_ua_id PRIMARY KEY NONCLUSTERED (ua_id),
    CONSTRAINT UQ_tbl_user_agents_user_agent UNIQUE CLUSTERED (user_agent)
);
```

- `user_agent` carries the **unique clustered** index, exactly as
  specified — the "does this UA already exist" check (step A of the
  insert flow) becomes a clustered index seek on the string itself.
- `ua_id` is a nonclustered PK. It's still the value returned via
  `SCOPE_IDENTITY()` and stored on `tbl_bi_clicks`.
- No `FOREIGN KEY` from `tbl_bi_clicks` to this table — consistent with
  how `sub_id` on `tbl_bi_clicks` doesn't have an enforced FK to
  `tbl_websites_subid` either. On a table this hot, skipping FK
  validation on every insert is deliberate; correctness is guaranteed by
  the proc's get-or-create logic, not by a constraint.

File: `01_create_tbl_user_agents.sql`

### 2. Alter `dbo.tbl_bi_clicks`

```sql
ALTER TABLE dbo.tbl_bi_clicks ADD request_ua_id INT NULL;
ALTER TABLE dbo.tbl_bi_clicks ADD click_ua_id INT NULL;
```

Both nullable — a metadata-only change on SQL Server (no table rewrite),
and consistent with the fact that a UA string won't always be available
(same reasoning as the existing nullable `visitor_ip`/`request_ip`/`referrer`
columns).

File: `02_alter_tbl_bi_clicks.sql`

### 3. New proc version: `dbo.bi_click_insert_internal_v5`

Cloned from `v4`, adding:

- Two new nullable input parameters, appended after `@request_id`:
  `@request_ua VARCHAR(512) = NULL`, `@click_ua VARCHAR(512) = NULL`.
- Two new locals: `@v_request_ua_id INT`, `@v_click_ua_id INT`.
- Defensive truncation mirroring the existing `visitor_ip`/`request_ip`
  handling (leave room for a `...` suffix instead of erroring if a caller
  ever sends something longer than the column):
  ```sql
  IF LEN(@request_ua) > 507 SET @request_ua = LEFT(@request_ua,507)+'...';
  IF LEN(@click_ua)   > 507 SET @click_ua   = LEFT(@click_ua,507)+'...';
  ```
- Two get-or-create blocks, placed right after the existing `sub_id`
  block, each following the exact same shape:
  1. `SELECT @v_..._ua_id = ua_id FROM dbo.tbl_user_agents WITH(NOLOCK) WHERE user_agent = @...`
  2. If not found: `BEGIN TRY` insert + `SCOPE_IDENTITY()`; `BEGIN CATCH`
     re-select (handles the concurrent-insert unique-violation race the
     same way the `sub_id` block does).
  - Small optimization: if `@click_ua = @request_ua` (the common case —
    request and click usually come from the same browser), reuse
    `@v_request_ua_id` instead of doing a second lookup/insert.
- `INSERT INTO dbo.tbl_bi_clicks` extended with `request_ua_id,
  click_ua_id` columns / `@v_request_ua_id, @v_click_ua_id` values.

File: `03_bi_click_insert_internal_v5.sql`

**Note on versioning:** the proc already carries a `v4` suffix with a
changelog comment at the top (see `-- v4 2026-05-19 - new input parameter
@request_id`). Since this is a breaking signature change (new required
position in the parameter list, even though both new params default to
NULL), following the existing convention it should ship as `v5` rather
than mutating `v4` in place, so any caller pinned to the `v4` name keeps
working unchanged during rollout.

**Out of scope (call out explicitly if not wanted):** `bi_click_insert_invalid_v4`
and `bi_click_insert_invalid_v4`'s callers are not touched — invalid/banned
clicks won't get `request_ua_id`/`click_ua_id` populated unless a follow-up
task extends that proc too.

## Rollout steps

1. Deploy `01_create_tbl_user_agents.sql` (new table, zero risk, no
   existing readers/writers).
2. Deploy `02_alter_tbl_bi_clicks.sql` (`ALTER TABLE ... ADD` of two
   nullable INT columns — metadata-only, no table lock upgrade concerns
   beyond the usual schema-modification lock, no rewrite).
3. Deploy `03_bi_click_insert_internal_v5.sql` (`CREATE OR ALTER`, so it's
   safe to run repeatedly / idempotent).
4. Update the calling application/API layer to:
   - Call `bi_click_insert_internal_v5` instead of `v4`.
   - Pass the server-side UA header as `@request_ua` and the
     browser-reported UA (if collected separately, e.g. via JS beacon) as
     `@click_ua`. If only one UA string is available, pass it for both
     parameters or leave the other NULL per product decision.
5. Leave `v4` in place (do not drop it) until all callers have migrated,
   then remove it in a later cleanup task.

## Testing / acceptance criteria

- [ ] `tbl_user_agents` created with clustered unique index on
      `user_agent` and nonclustered PK on `ua_id`.
- [ ] `tbl_bi_clicks` has new nullable `request_ua_id`, `click_ua_id`
      columns.
- [ ] Calling `bi_click_insert_internal_v5` with a brand-new UA string
      inserts a new row into `tbl_user_agents` and stores the resulting
      `ua_id` on the click row.
- [ ] Calling it again with the *same* UA string does **not** insert a
      duplicate row in `tbl_user_agents`; the existing `ua_id` is reused.
- [ ] Calling it with `@request_ua`/`@click_ua` both `NULL` leaves
      `request_ua_id`/`click_ua_id` `NULL` on the click row (no error).
- [ ] Concurrency test: fire many parallel inserts with the same
      brand-new UA string simultaneously — exactly one row should end up
      in `tbl_user_agents` for that string (validates the TRY/CATCH race
      handling), and no proc call should fail.
- [ ] Existing `v4` callers are unaffected (proc left untouched).
- [ ] No measurable regression in insert latency/throughput on
      `tbl_bi_clicks` under load (this proc is on the hot path).

## Risks / considerations

- **Race condition on first insert of a new UA** — handled via TRY/CATCH
  + re-select, identical to the existing `sub_id` pattern; no new class
  of risk introduced.
- **Index key size** — `VARCHAR(512)` with a single-byte collation is
  512 bytes, under SQL Server's 900-byte clustered-index key limit; safe
  as specified. If the server's default collation is ever changed to a
  double-byte/UTF-16-backed collation this would need re-checking.
- **Hot-path performance** — every click insert now does up to 2 extra
  lookups (deduped to 1 in the common case where request/click UA match).
  Since the lookup is a clustered index seek on `user_agent`, cost should
  be comparable to the existing `sub_id` lookup already on this path.
- **Unbounded growth of `tbl_user_agents`** — UA strings have long-tail
  variation (versions, bot strings, etc.) but are still bounded and
  reused heavily; growth should be modest compared to `tbl_bi_clicks`
  itself. No action needed initially; monitor row count post-launch.
- **No FK enforcement** — intentional trade-off for insert performance,
  matching the existing `sub_id` column; flag this explicitly to
  reviewers since it's a deliberate deviation from "always add the FK."

## Suggested Jira breakdown

1. **[DB] Create `tbl_user_agents` table** — run
   `01_create_tbl_user_agents.sql` against target environment(s).
2. **[DB] Alter `tbl_bi_clicks`: add `request_ua_id`, `click_ua_id`** —
   run `02_alter_tbl_bi_clicks.sql`.
3. **[DB] Create `bi_click_insert_internal_v5`** with UA get-or-create
   logic — run `03_bi_click_insert_internal_v5.sql`; code review against
   `v4` diff.
4. **[App/API] Switch click-insert call site(s) to `v5`**, wire up
   `@request_ua` (server header) / `@click_ua` (client-reported UA, if
   applicable).
5. **[QA] Concurrency + acceptance test pass** per checklist above, in a
   staging environment with production-like click volume.
6. **[Ops] Rollout + monitor** — verify `tbl_user_agents` growth rate and
   insert latency on `tbl_bi_clicks` post-deploy; keep `v4` around as a
   fallback until fully migrated.
7. *(Follow-up, optional)* Extend `bi_click_insert_invalid_v4` similarly
   if UA tracking is also wanted for invalid/banned clicks.
