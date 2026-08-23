-- =====================================================================
-- Diagnostic: what values does ck_sla_master_classification allow?
--
-- Extract the CHECK constraint's definition so we know exactly which
-- classification values the schema permits today. The template INSERT
-- must use one of these -- OR the constraint must be widened first.
-- =====================================================================
SET NOCOUNT ON;

SELECT
    cc.name                     AS ConstraintName,
    OBJECT_NAME(cc.parent_object_id) AS TableName,
    COL_NAME(cc.parent_object_id, cc.parent_column_id) AS ColumnName,
    cc.definition               AS AllowedValuesDefinition,
    cc.is_disabled              AS IsDisabled
FROM sys.check_constraints cc
WHERE cc.name = 'ck_sla_master_classification';

-- Also list every distinct classification currently in the table so
-- the widened constraint doesn't accidentally reject existing data.
-- (Aliased as MasterRowCount because RowCount is a reserved word.)
SELECT DISTINCT classification, COUNT(*) AS MasterRowCount
FROM grac_new.sla_master
WHERE classification IS NOT NULL
GROUP BY classification
ORDER BY classification;
