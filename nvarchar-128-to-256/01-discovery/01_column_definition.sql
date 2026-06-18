/* =============================================================================
   01_column_definition.sql
   Purpose: Confirm the target column's definition and every index it belongs to.
   Run against: the target database.
   Share back: both result sets.
   ============================================================================= */
DECLARE @Schema sysname = N'dbo',        -- <<< set target
        @Table  sysname = N'MyTable',    -- <<< set target
        @Column sysname = N'MyCol';      -- <<< set target

DECLARE @ObjectId int = OBJECT_ID(QUOTENAME(@Schema) + N'.' + QUOTENAME(@Table));
DECLARE @ColumnId int = COLUMNPROPERTY(@ObjectId, @Column, 'ColumnId');

/* --- A) Column definition ------------------------------------------------- */
SELECT  c.name                AS column_name,
        t.name                AS type_name,
        c.max_length / 2      AS declared_nchar_len,   -- nvarchar => bytes/2
        c.is_nullable,
        c.is_computed,
        c.collation_name,
        dc.definition         AS default_constraint
FROM    sys.columns c
JOIN    sys.types   t  ON t.user_type_id = c.user_type_id
LEFT JOIN sys.default_constraints dc
       ON dc.parent_object_id = c.object_id AND dc.parent_column_id = c.column_id
WHERE   c.object_id = @ObjectId
  AND   c.name = @Column;

/* --- B) Indexes that include the column (key or INCLUDE) ------------------ */
SELECT  i.name                AS index_name,
        i.type_desc,
        i.is_unique,
        i.is_primary_key,
        i.is_unique_constraint,
        ic.key_ordinal,
        ic.is_included_column,
        ic.is_descending_key
FROM    sys.indexes i
JOIN    sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
WHERE   ic.object_id = @ObjectId
  AND   ic.column_id = @ColumnId
ORDER BY i.is_primary_key DESC, i.name;
