# Extend column `nvarchar(128)` → `nvarchar(256)`

Analysis, performance estimation, and change estimation for widening a heavily-used
`nvarchar(128)` column to `nvarchar(256)` in MS SQL Server.

## Target

| Item | Value |
|------|-------|
| Schema  | _TBD_ |
| Table   | _TBD_ |
| Column  | _TBD_ |
| SQL Server version | _TBD_ |
| Column role (PK / FK target / indexed / plain) | _TBD_ |

## Workflow (3 stages)

1. **Discovery** (`01-discovery/`) — turn "used in a lot of procedures" into an
   exact, countable dependency inventory using `sys.*` catalog queries.
2. **Assessment** (`02-assessment/`) — interpret the inventory: performance risks
   (memory grants, index key limits) and correctness risks (silent truncation, FK type mismatch).
3. **Migration** (`03-migration/`) — the `ALTER` script(s), dependent-object updates,
   and a rollback note, sequenced for a safe deploy.

## Status

- [ ] Stage 0 — fill in target details above
- [ ] Stage 1 — discovery scripts authored & run
- [ ] Stage 2 — assessment written
- [ ] Stage 3 — migration + rollback drafted

> Scaffold only. Steps to be agreed before authoring scripts.
