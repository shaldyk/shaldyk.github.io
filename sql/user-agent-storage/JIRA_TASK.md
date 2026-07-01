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
  I/O; most UA values repeat across many clicks, so an INT surrogate key
  is far cheaper.
- The dedup-table + get-or-create pattern is already proven in this
  codebase for sub_id_string, so the failure modes (race conditions,
  index design) are already understood.

Schema changes:
1. New table dbo.tbl_user_agents:
   - ua_id INT IDENTITY(1,1), nonclustered PRIMARY KEY
   - user_agent VARCHAR(512), UNIQUE CLUSTERED index (as required)
   - No FK from tbl_bi_clicks to this table (matches sub_id, which also
     has no enforced FK) - deliberate trade-off for insert performance
     on a hot-path table.
2. ALTER TABLE dbo.tbl_bi_clicks ADD request_ua_id INT NULL, click_ua_id INT NULL
   (both nullable, metadata-only change, no table rewrite).
3. New proc version dbo.bi_click_insert_internal_v5 (cloned from v4):
   - New nullable params @request_ua VARCHAR(512) = NULL, @click_ua VARCHAR(512) = NULL
   - Defensive truncation mirroring visitor_ip/request_ip handling
   - Two get-or-create blocks (lookup -> TRY/CATCH insert -> re-lookup),
     same shape as the existing sub_id block
   - Optimization: if click_ua = request_ua, reuse the same id instead of
     a second lookup
   - v4 is left untouched/running in parallel until callers migrate

Out of scope (call out if wanted): bi_click_insert_invalid_v4 (banned-IP
and duplicate-click path) is not touched, so invalid clicks won't get
request_ua_id/click_ua_id unless a follow-up task extends that proc too.

Reference implementation / SQL scripts:
GitHub PR: https://github.com/shaldyk/shaldyk.github.io/pull/1
Branch: claude/user-agent-sql-storage-rj3pyu
Path: sql/user-agent-storage/
```

---

## Acceptance Criteria (paste into "Acceptance Criteria" or a checklist field)

```
- tbl_user_agents created with clustered unique index on user_agent and nonclustered PK on ua_id.
- tbl_bi_clicks has new nullable request_ua_id, click_ua_id columns.
- Calling bi_click_insert_internal_v5 with a brand-new UA string inserts a new row into tbl_user_agents and stores the resulting ua_id on the click row.
- Calling it again with the same UA string does not insert a duplicate row in tbl_user_agents; the existing ua_id is reused.
- Calling it with @request_ua/@click_ua both NULL leaves request_ua_id/click_ua_id NULL on the click row (no error).
- Concurrency test: many parallel inserts with the same brand-new UA string simultaneously result in exactly one row in tbl_user_agents for that string, and no proc call fails.
- Existing v4 callers are unaffected (proc left untouched).
- No measurable regression in insert latency/throughput on tbl_bi_clicks under load.
```

---

## Risks / Notes (paste into a "Risks" or comment field)

```
- Race condition on first insert of a new UA: handled via TRY/CATCH + re-select, identical to the existing sub_id pattern.
- Index key size: VARCHAR(512) with single-byte collation = 512 bytes, under SQL Server's 900-byte clustered-index key limit.
- Hot-path performance: up to 2 extra lookups per click insert (deduped to 1 when request/click UA match); cost comparable to the existing sub_id lookup.
- No FK enforcement from tbl_bi_clicks to tbl_user_agents - deliberate, matches sub_id; flag to reviewers as an intentional deviation.
- Monitor tbl_user_agents row growth post-launch (expected to be modest vs. tbl_bi_clicks).
```

---

## Subtasks (create one Jira subtask per line below)

```
[DB] Create tbl_user_agents table
[DB] Alter tbl_bi_clicks: add request_ua_id, click_ua_id
[DB] Create bi_click_insert_internal_v5 with UA get-or-create logic
[App/API] Switch click-insert call site(s) to v5, wire up @request_ua/@click_ua
[QA] Concurrency + acceptance test pass in staging with production-like click volume
[Ops] Rollout + monitor tbl_user_agents growth and tbl_bi_clicks insert latency
[Follow-up, optional] Extend bi_click_insert_invalid_v4 for UA tracking on invalid/banned clicks
```
