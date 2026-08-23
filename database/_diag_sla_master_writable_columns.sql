-- =====================================================================
-- Diagnostic: which grac_new.sla_master columns are writable?
--
-- Shows every column plus flags for computed / identity / nullability
-- so the INSERT template can leave out the non-writable ones.
-- =====================================================================
SET NOCOUNT ON;

IF OBJECT_ID('grac_new.sla_master','U') IS NULL
BEGIN
    SELECT 'grac_new.sla_master MISSING' AS Diagnosis;
    RETURN;
END

SELECT
    c.column_id                                                   AS Ordinal,
    c.name                                                        AS ColumnName,
    t.name                                                        AS DataType,
    c.max_length                                                  AS MaxLength,
    c.is_nullable                                                 AS IsNullable,
    c.is_identity                                                 AS IsIdentity,
    c.is_computed                                                 AS IsComputed,
    CASE WHEN c.is_identity = 1 OR c.is_computed = 1
         THEN 'NO (skip in INSERT)'
         ELSE 'YES' END                                           AS WritableInInsert,
    -- Show the formula for computed columns so we know how the value is
    -- derived (usually sla_code = CONCAT('SLA-', ...) from sla_id).
    (SELECT cc.definition
       FROM sys.computed_columns cc
      WHERE cc.object_id = c.object_id AND cc.column_id = c.column_id) AS ComputedDefinition
FROM sys.columns c
JOIN sys.types   t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('grac_new.sla_master')
ORDER BY c.column_id;
