/* =============================================================================
   04_hardcoded_128.sql
   Purpose: Hunt for hard-coded nvarchar(128) that would SILENTLY TRUNCATE a
            256-char value even after the table column is widened. This is the
            highest-value correctness check.
   Run against: the target database.
   Share back: all four result sets.
   ============================================================================= */
DECLARE @Schema sysname = N'dbo',        -- <<< set target (used only to scope the column-name text search; bodies are DB-wide)
        @Column sysname = N'MyCol';      -- <<< set target

/* --- A) Routine PARAMETERS declared nvarchar(128) (max_length 256 bytes) -- */
SELECT  OBJECT_SCHEMA_NAME(p.object_id) AS obj_schema,
        OBJECT_NAME(p.object_id)        AS obj_name,
        o.type_desc,
        p.name                          AS param_name,
        p.max_length / 2                AS nchar_len
FROM    sys.parameters p
JOIN    sys.types t  ON t.user_type_id = p.user_type_id
JOIN    sys.objects o ON o.object_id = p.object_id
WHERE   t.name = 'nvarchar' AND p.max_length = 256
ORDER BY obj_schema, obj_name, param_name;

/* --- B) Module BODIES containing the literal text 'nvarchar(128)' ---------- */
/*        Catches local variables, CAST/CONVERT, temp-table column defs.      */
SELECT  OBJECT_SCHEMA_NAME(m.object_id) AS obj_schema,
        OBJECT_NAME(m.object_id)        AS obj_name,
        o.type_desc
FROM    sys.sql_modules m
JOIN    sys.objects o ON o.object_id = m.object_id
WHERE   m.definition LIKE '%nvarchar(128)%' COLLATE Latin1_General_CI_AI
   OR   m.definition LIKE '%nvarchar (128)%' COLLATE Latin1_General_CI_AI
ORDER BY obj_schema, obj_name;

/* --- C) User-defined TABLE TYPES / TVP columns at nvarchar(128) ----------- */
SELECT  tt.name                AS table_type,
        c.name                 AS column_name,
        c.max_length / 2       AS nchar_len
FROM    sys.table_types tt
JOIN    sys.columns c ON c.object_id = tt.type_table_object_id
JOIN    sys.types t   ON t.user_type_id = c.user_type_id
WHERE   t.name = 'nvarchar' AND c.max_length = 256
ORDER BY tt.name, c.name;

/* --- D) Any OTHER table column with the same NAME at nvarchar(128) -------- */
/*        Often a sign of a denormalized copy that should match.             */
SELECT  OBJECT_SCHEMA_NAME(c.object_id) AS obj_schema,
        OBJECT_NAME(c.object_id)        AS table_name,
        c.name                          AS column_name,
        c.max_length / 2                AS nchar_len
FROM    sys.columns c
JOIN    sys.types t ON t.user_type_id = c.user_type_id
WHERE   c.name = @Column
  AND   t.name = 'nvarchar' AND c.max_length = 256
ORDER BY obj_schema, table_name;
