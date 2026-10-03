-- =====================================================================
-- 387 ROLLBACK  Risk practice-instance mapping / treatment task links
--
--   * Drops risk_treatment_task_link and the 387 procedures / function.
--   * Collapses instance rows back to ONE practice-level row per
--     (risk, practice): the Primary row (or the oldest) is kept with its
--     instance columns cleared; the other instance rows of the same
--     practice are deleted (their contribution rows stay under the
--     practice, which is what the 266 procedures expect).
--   * Restores uq_pm_risk_practice_map (risk, practice) and drops the
--     instance columns.
--   * Re-run 263 (sp_risk_treatment_state), 267 (sp_risk_mapping_get)
--     and 354 (sp_risk_mapping_sync_primary) afterwards to restore the
--     previous procedure bodies.
-- Revert the matching API / Web / JS changes too. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.risk_treatment_task_link','U') IS NOT NULL
    DROP TABLE grac_practice.risk_treatment_task_link;
DROP PROCEDURE IF EXISTS grac_practice.sp_risk_treatment_task_link;
DROP PROCEDURE IF EXISTS grac_practice.sp_risk_treatment_task_unlink;
DROP PROCEDURE IF EXISTS grac_practice.sp_risk_open_task_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_practice_picker_instances;
DROP PROCEDURE IF EXISTS grac_practice.sp_risk_practice_map_expand_instances;
DROP PROCEDURE IF EXISTS grac_practice.sp_risk_practice_instance_unmap;
DROP PROCEDURE IF EXISTS grac_practice.sp_risk_practice_instance_map;
DROP FUNCTION  IF EXISTS grac_practice.fn_risk_instance_dependencies;
GO

IF COL_LENGTH('grac_practice.risk_practice_map','practice_instance_id') IS NOT NULL
BEGIN
    EXEC sp_executesql N'
    ;WITH ranked AS (
        SELECT risk_practice_map_id,
               ROW_NUMBER() OVER (PARTITION BY risk_register_id, practice_id
                                  ORDER BY CASE WHEN map_source_code = N''Primary'' THEN 0 ELSE 1 END,
                                           risk_practice_map_id) AS rn
          FROM grac_practice.risk_practice_map)
    DELETE m FROM grac_practice.risk_practice_map m
      JOIN ranked r ON r.risk_practice_map_id = m.risk_practice_map_id
     WHERE r.rn > 1;
    UPDATE grac_practice.risk_practice_map
       SET practice_instance_id = NULL, practice_instance_name = NULL, practice_instance_code = NULL;';
END
GO

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_risk_practice_map_instance'
              AND object_id = OBJECT_ID('grac_practice.risk_practice_map'))
    DROP INDEX ux_pm_risk_practice_map_instance ON grac_practice.risk_practice_map;
IF COL_LENGTH('grac_practice.risk_practice_map','practice_instance_key') IS NOT NULL
    ALTER TABLE grac_practice.risk_practice_map DROP COLUMN practice_instance_key;
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_risk_practice_map_instance')
    ALTER TABLE grac_practice.risk_practice_map DROP CONSTRAINT fk_pm_risk_practice_map_instance;
IF COL_LENGTH('grac_practice.risk_practice_map','practice_instance_id') IS NOT NULL
    ALTER TABLE grac_practice.risk_practice_map DROP COLUMN practice_instance_id;
IF COL_LENGTH('grac_practice.risk_practice_map','practice_instance_name') IS NOT NULL
    ALTER TABLE grac_practice.risk_practice_map DROP COLUMN practice_instance_name;
IF COL_LENGTH('grac_practice.risk_practice_map','practice_instance_code') IS NOT NULL
    ALTER TABLE grac_practice.risk_practice_map DROP COLUMN practice_instance_code;
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'uq_pm_risk_practice_map')
    ALTER TABLE grac_practice.risk_practice_map
        ADD CONSTRAINT uq_pm_risk_practice_map UNIQUE(risk_register_id, practice_id);
GO
PRINT 'ROLLBACK 387 complete -- now re-run 263, 267 and 354.';
GO
