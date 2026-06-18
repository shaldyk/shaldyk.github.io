/* =============================================================================
   03_module_dependencies.sql
   Purpose: List programmable objects (procs, functions, views, triggers) that
            depend on the target column or table. SCHEMABINDING flagged because
            those must be unbound before any type change.
   Run against: the target database.
   Note: sys.sql_expression_dependencies can miss column-level granularity for
         dynamic SQL and SELECT * ; pair this with the text scan in script 04.
   Share back: both result sets.
   ============================================================================= */
DECLARE @Schema sysname = N'dbo',        -- <<< set target
        @Table  sysname = N'MyTable',    -- <<< set target
        @Column sysname = N'MyCol';      -- <<< set target

DECLARE @ObjectId int = OBJECT_ID(QUOTENAME(@Schema) + N'.' + QUOTENAME(@Table));
DECLARE @ColumnId int = COLUMNPROPERTY(@ObjectId, @Column, 'ColumnId');

/* --- A) Dependencies on the specific COLUMN ------------------------------- */
SELECT DISTINCT
        OBJECT_SCHEMA_NAME(d.referencing_id)              AS obj_schema,
        OBJECT_NAME(d.referencing_id)                     AS obj_name,
        o.type_desc,
        OBJECTPROPERTY(d.referencing_id,'IsSchemaBound')  AS is_schemabound
FROM    sys.sql_expression_dependencies d
JOIN    sys.objects o ON o.object_id = d.referencing_id
WHERE   d.referenced_id = @ObjectId
  AND  (d.referenced_minor_id = @ColumnId OR d.referenced_minor_id = 0)
ORDER BY o.type_desc, obj_name;

/* --- B) All dependencies on the TABLE (broader blast radius) -------------- */
SELECT  o.type_desc,
        COUNT(DISTINCT d.referencing_id) AS dependent_object_count
FROM    sys.sql_expression_dependencies d
JOIN    sys.objects o ON o.object_id = d.referencing_id
WHERE   d.referenced_id = @ObjectId
GROUP BY o.type_desc
ORDER BY dependent_object_count DESC;
