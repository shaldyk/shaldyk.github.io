/* =============================================================================
   05_environment_and_blockers.sql
   Purpose: Detect features that change the ALTER mechanics or block a
            metadata-only change (replication/CDC, Always Encrypted, indexed
            views, full-text, computed columns, CHECK constraints).
   Run against: the target database.
   Share back: every result set that returns rows.
   ============================================================================= */
DECLARE @Schema sysname = N'dbo',        -- <<< set target
        @Table  sysname = N'MyTable',    -- <<< set target
        @Column sysname = N'MyCol';      -- <<< set target

DECLARE @ObjectId int = OBJECT_ID(QUOTENAME(@Schema) + N'.' + QUOTENAME(@Table));
DECLARE @ColumnId int = COLUMNPROPERTY(@ObjectId, @Column, 'ColumnId');

/* --- A) Always Encrypted on the column ------------------------------------ */
SELECT  c.name AS column_name, c.encryption_type_desc, c.encryption_algorithm_name
FROM    sys.columns c
WHERE   c.object_id = @ObjectId AND c.column_id = @ColumnId
  AND   c.encryption_type IS NOT NULL;

/* --- B) Replication / CDC / Change Tracking ------------------------------- */
SELECT  OBJECTPROPERTY(@ObjectId,'TableIsReplicated')      AS is_replicated,
        OBJECTPROPERTY(@ObjectId,'TableHasChangeTracking') AS has_change_tracking,
        (SELECT is_cdc_enabled FROM sys.databases WHERE database_id = DB_ID()) AS db_cdc_enabled;

/* --- C) Computed columns referencing our column --------------------------- */
SELECT  c.name AS computed_column, cc.definition
FROM    sys.computed_columns cc
JOIN    sys.columns c ON c.object_id = cc.object_id AND c.column_id = cc.column_id
WHERE   cc.object_id = @ObjectId
  AND   cc.definition LIKE '%' + QUOTENAME(@Column) + '%';

/* --- D) CHECK constraints referencing our column -------------------------- */
SELECT  ck.name AS check_constraint, ck.definition
FROM    sys.check_constraints ck
WHERE   ck.parent_object_id = @ObjectId
  AND   ck.definition LIKE '%' + QUOTENAME(@Column) + '%';

/* --- E) Indexed (materialized) views referencing the table ---------------- */
SELECT DISTINCT OBJECT_SCHEMA_NAME(v.object_id) AS view_schema,
                OBJECT_NAME(v.object_id)        AS view_name
FROM    sys.views v
JOIN    sys.indexes i ON i.object_id = v.object_id AND i.index_id = 1  -- has clustered idx => materialized
JOIN    sys.sql_expression_dependencies d ON d.referencing_id = v.object_id
WHERE   d.referenced_id = @ObjectId;

/* --- F) Full-text index on the column ------------------------------------- */
SELECT  c.name AS fulltext_column
FROM    sys.fulltext_index_columns fic
JOIN    sys.columns c ON c.object_id = fic.object_id AND c.column_id = fic.column_id
WHERE   fic.object_id = @ObjectId AND fic.column_id = @ColumnId;

/* --- G) Row count + table size (sizes the maintenance window if rebuilds) - */
SELECT  SUM(p.rows) AS approx_row_count
FROM    sys.partitions p
WHERE   p.object_id = @ObjectId AND p.index_id IN (0,1);
