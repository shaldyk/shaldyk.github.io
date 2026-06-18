/* =============================================================================
   02_foreign_keys.sql
   Purpose: Find foreign-key relationships involving the target column.
            FK columns MUST share the same type, so if this column is a key
            referenced by other tables, those columns must be widened too.
   Run against: the target database.
   Share back: both result sets (even if empty).
   ============================================================================= */
DECLARE @Schema sysname = N'dbo',        -- <<< set target
        @Table  sysname = N'MyTable',    -- <<< set target
        @Column sysname = N'MyCol';      -- <<< set target

DECLARE @ObjectId int = OBJECT_ID(QUOTENAME(@Schema) + N'.' + QUOTENAME(@Table));
DECLARE @ColumnId int = COLUMNPROPERTY(@ObjectId, @Column, 'ColumnId');

/* --- A) Inbound: other tables whose FK references OUR column -------------- */
/*        (these child columns must be widened in lockstep)                   */
SELECT  fk.name                                    AS fk_name,
        OBJECT_SCHEMA_NAME(fkc.parent_object_id)   AS child_schema,
        OBJECT_NAME(fkc.parent_object_id)          AS child_table,
        cChild.name                                AS child_column,
        cChild.max_length / 2                      AS child_nchar_len,
        OBJECT_NAME(fkc.referenced_object_id)      AS parent_table,
        cParent.name                               AS parent_column
FROM    sys.foreign_key_columns fkc
JOIN    sys.foreign_keys fk      ON fk.object_id = fkc.constraint_object_id
JOIN    sys.columns cParent ON cParent.object_id = fkc.referenced_object_id
                           AND cParent.column_id = fkc.referenced_column_id
JOIN    sys.columns cChild  ON cChild.object_id  = fkc.parent_object_id
                           AND cChild.column_id  = fkc.parent_column_id
WHERE   fkc.referenced_object_id = @ObjectId
  AND   fkc.referenced_column_id = @ColumnId;

/* --- B) Outbound: OUR column is itself an FK pointing elsewhere ----------- */
SELECT  fk.name                                    AS fk_name,
        OBJECT_NAME(fkc.parent_object_id)          AS our_table,
        cChild.name                                AS our_column,
        OBJECT_SCHEMA_NAME(fkc.referenced_object_id) AS parent_schema,
        OBJECT_NAME(fkc.referenced_object_id)      AS parent_table,
        cParent.name                               AS parent_column,
        cParent.max_length / 2                     AS parent_nchar_len
FROM    sys.foreign_key_columns fkc
JOIN    sys.foreign_keys fk      ON fk.object_id = fkc.constraint_object_id
JOIN    sys.columns cParent ON cParent.object_id = fkc.referenced_object_id
                           AND cParent.column_id = fkc.referenced_column_id
JOIN    sys.columns cChild  ON cChild.object_id  = fkc.parent_object_id
                           AND cChild.column_id  = fkc.parent_column_id
WHERE   fkc.parent_object_id = @ObjectId
  AND   fkc.parent_column_id = @ColumnId;
