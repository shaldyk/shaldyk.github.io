# Jira Ticket — Copy/Paste Blocks

Each section below maps to one Jira field. Copy the content of a block
(not the heading) directly into the corresponding field.

---

## Summary (paste into "Summary")

```
Keeping user agent data in tbl_bi_clicks (MS SQL Server)
```

---

## Description (paste into "Description")

```
Store the raw HTTP User-Agent string associated with each click, without
bloating tbl_bi_clicks with a repeated VARCHAR(512) value on every row.
De-duplicate User-Agent strings into a new lookup table (tbl_user_agents)
and store only the two resulting surrogate IDs on tbl_bi_clicks:

- request_ua_id - resolved from the server/request-side User-Agent (@request_ua)
- click_ua_id   - resolved from the browser/click-side User-Agent (@click_ua)

This follows the existing sub_id / tbl_websites_subid "get-or-create"
pattern already used in dbo.bi_click_insert_internal_v4: look up the
value, and if it doesn't exist yet, insert it and handle the race with a
TRY/CATCH re-lookup.

Why this design:
- tbl_bi_clicks is a very high-volume, append-mostly table. Storing a
  512-byte string twice per row would meaningfully increase row size and
  I/O; most UA values repeat, so an INT surrogate key is far cheaper.
- Surrogate keys also make large analytics cheaper: aggregations GROUP BY
  a 4-byte int instead of a 512-byte string, and ua_id -> user_agent
  resolution is a hash join over a small, cached lookup table.

Schema changes:
1. New table dbo.tbl_user_agents (Design A):
   - ua_id INT IDENTITY(1,1) -> CLUSTERED primary key (append-only inserts)
   - user_agent VARCHAR(512) COLLATE Latin1_General_CI_AS -> UNIQUE
     NONCLUSTERED index (covering lookup; collation matches the DB default
     and sub_id_string, so dedup is case-insensitive)
   - creation_date_time DATETIME NULL -> "first seen" timestamp
   - DATA_COMPRESSION = PAGE
   - No FK from tbl_bi_clicks (matches sub_id, which also has no enforced
     FK) - deliberate trade-off for insert performance on a hot-path table.
   Note: this differs from tbl_websites_subid (which clusters on the value)
   because that table has a leading low-cardinality int (website_id) that
   ours lacks; clustering a lone varchar(512) would split data pages on the
   hot insert path under continuous UA churn.
2. ALTER TABLE dbo.tbl_bi_clicks ADD request_ua_id INT NULL, click_ua_id INT NULL
   (both nullable, metadata-only change, no table rewrite).
3. New internal proc dbo.bi_click_insert_internal_v5 (cloned from v4):
   - New nullable params @request_ua, @click_ua VARCHAR(512) = NULL
   - Defensive truncation mirroring visitor_ip/request_ip handling
   - Two get-or-create blocks (lookup -> TRY/CATCH insert -> re-lookup),
     same shape as the existing sub_id block; new rows set
     creation_date_time = GETDATE()
   - Empty-string UA treated as no UA via NULLIF(@ua,'') IS NOT NULL
   - No click_ua = request_ua shortcut (a variable comparison resolves in
     the DB default collation, not guaranteed to match the column's; the
     column-based lookup is correct by construction under any collation)
   - Best-effort: a UA-capture failure never fails the click insert
4. New wrapper proc dbo.bi_click_insert_v5 (cloned from bi_click_insert_v4):
   - Same two new params, passed through to bi_click_insert_internal_v5
5. ALTER TABLE dbo.tbl_bi_clicks_invalid_p ADD request_ua_id INT NULL,
   click_ua_id INT NULL (same as tbl_bi_clicks, for invalid/banned clicks).
6. New invalid-clicks proc dbo.bi_click_insert_invalid_v5 (cloned from
   bi_click_insert_invalid_v4): same @request_ua/@click_ua params and
   get-or-create logic, inserts the ids into tbl_bi_clicks_invalid_p. The
   internal v5 proc's two EXEC calls (duplicate-click and banned-IP paths)
   are updated to call this v5 and pass the UA params through.

v4 (wrapper, internal, and invalid) is left untouched/running in parallel
until callers migrate.

Prerequisites:
- DATA_COMPRESSION = PAGE requires SQL Server 2016 SP1+ (any edition).
- OPTIMIZE_FOR_SEQUENTIAL_KEY = ON requires SQL Server 2019+ (remove on
  older versions).

Acceptance criteria:
- tbl_user_agents created: clustered PK on ua_id, unique nonclustered CI_AS index on user_agent, PAGE compression.
- tbl_bi_clicks and tbl_bi_clicks_invalid_p have new nullable request_ua_id, click_ua_id columns.
- New UA string inserts a new row into tbl_user_agents (with creation_date_time set) and stores the resulting ua_id on the click row.
- Same UA string again does not insert a duplicate row; the existing ua_id is reused.
- @request_ua/@click_ua NULL or empty string leaves the id NULL and creates no junk empty-string row.
- Two UAs differing only in case collapse to a single row (CI_AS collation).
- Concurrency: many parallel inserts of the same brand-new UA result in exactly one row, and no proc call fails.
- Invalid/banned clicks (duplicate-click and banned-IP paths) also populate request_ua_id/click_ua_id in tbl_bi_clicks_invalid_p.
- Existing v4 callers are unaffected (v4 procs left untouched).
- No measurable regression in insert latency/throughput on tbl_bi_clicks under load.

Risks / notes:
- Race on first insert of a new UA: handled via TRY/CATCH + re-select, identical to the existing sub_id pattern.
- Index key size: VARCHAR(512) single-byte = 512 bytes, under SQL Server's 900-byte nonclustered-index key limit.
- Hot-path performance: up to 2 extra lookups per click insert, each a seek on the small, cached tbl_user_agents; comparable to the existing sub_id lookup.
- tbl_user_agents growth: UA strings have a continuously growing long tail (bots/spoofing), so plan for ongoing (not saturating) inserts. Still modest vs. tbl_bi_clicks; PAGE compression mitigates size. Monitor row count post-launch.
- No FK enforcement from tbl_bi_clicks to tbl_user_agents - deliberate, matches sub_id; flag to reviewers as an intentional deviation.
- Version prerequisites: PAGE compression (2016 SP1+), OPTIMIZE_FOR_SEQUENTIAL_KEY (2019+).

Implementation steps / progress (deploy order 01, 02, 05, 06, 03, 04):
- [x] DONE  [DB] Create tbl_user_agents table (01_create_tbl_user_agents.sql)
- [x] DONE  [DB] Alter tbl_bi_clicks: add request_ua_id, click_ua_id (02_alter_tbl_bi_clicks.sql)
- [x] DONE  [DB] Alter tbl_bi_clicks_invalid_p: add request_ua_id, click_ua_id (05_alter_tbl_bi_clicks_invalid_p.sql)
- [x] DONE  [DB] Create bi_click_insert_invalid_v5 with UA get-or-create logic (06_bi_click_insert_invalid_v5.sql)
- [x] DONE  [DB] Create bi_click_insert_internal_v5 with UA get-or-create logic; calls invalid_v5 (03_bi_click_insert_internal_v5.sql)
- [x] DONE  [DB] Create bi_click_insert_v5 wrapper proc (04_bi_click_insert_v5.sql)
- [ ] TODO  [App/API] Switch click-insert call site(s) to v5, wire up @request_ua/@click_ua
- [ ] TODO  [QA] Insertion acceptance test: new UA creates+stores ua_id, repeat UA is deduped, NULL/empty UA leaves ua_id NULL, invalid-click path populates the ids
- [ ] TODO  [Ops] Rollout + monitor tbl_user_agents growth and tbl_bi_clicks insert latency (volume/load behavior observed here, not gated by acceptance test)

Reference implementation / SQL scripts:
GitHub PR: https://github.com/shaldyk/shaldyk.github.io/pull/1
Branch: claude/user-agent-sql-storage-rj3pyu
Path: sql/user-agent-storage/  (files 01-06, deploy order 01,02,05,06,03,04)
```
