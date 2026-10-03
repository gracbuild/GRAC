-- =====================================================================
-- 388_gap_exception_practice_instance_mapping_rollback.sql
--
-- Reverts 388:
--   * drops sp_custom_gap_practice_instance_set and
--     sp_exception_request_practice_instance_set
--   * restores the 382 / 328 bodies of the two list procedures
--   * collapses instance rows back to ONE row per (entity, practice)
--     (keeps the oldest row), drops the instance columns / indexes and
--     restores the original unique constraints
--
-- AFTER RUNNING: re-run 387_risk_practice_instance_mapping.sql so
-- sp_risk_treatment_state goes back to the 387 body (the 388 body reads
-- custom_gap_practice_map.practice_instance_id, which this drops).
--
-- Safe to re-run. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_practice_instance_set;
DROP PROCEDURE IF EXISTS grac_practice.sp_exception_request_practice_instance_set;
GO

-- 382 body
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_practice_map_list
    @custom_gap_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.custom_gap_practice_map_id CustomGapPracticeMapId,
           m.custom_gap_id              CustomGapId,
           m.practice_id                PracticeId,
           COALESCE(p.practice_name, m.practice_name) PracticeName,
           COALESCE(p.practice_code, m.practice_code) PracticeCode,
           m.mapped_dt                  MappedDt
      FROM grac_practice.custom_gap_practice_map m
      LEFT JOIN grac_practice.practice p ON p.practice_id = m.practice_id
      JOIN grac_practice.record_status_master rs ON rs.record_status_id = m.record_status_id
     WHERE m.custom_gap_id = @custom_gap_id
       AND rs.status_code = N'Active'
     ORDER BY COALESCE(p.practice_name, m.practice_name);
END
GO

-- 328 body
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_practice_list
    @exception_request_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @exception_request_id IS NULL
        THROW 55230, 'sp_exception_request_practice_list: exception_request_id is required.', 1;

    SELECT
        x.exception_request_practice_id AS ExceptionRequestPracticeId,
        x.practice_id                   AS PracticeId,
        x.practice_name                 AS PracticeName,
        x.practice_code                 AS PracticeCode,
        x.linked_dt                     AS LinkedOn
      FROM grac_practice.exception_request_practice x
     WHERE x.exception_request_id = @exception_request_id
     ORDER BY x.exception_request_practice_id;
END
GO

-- ---- custom_gap_practice_map ----------------------------------------
IF COL_LENGTH('grac_practice.custom_gap_practice_map','practice_instance_id') IS NOT NULL
BEGIN
    ;WITH r AS (
        SELECT custom_gap_practice_map_id,
               ROW_NUMBER() OVER (PARTITION BY custom_gap_id, practice_id
                                  ORDER BY custom_gap_practice_map_id) AS rn
          FROM grac_practice.custom_gap_practice_map)
    DELETE m FROM grac_practice.custom_gap_practice_map m
      JOIN r ON r.custom_gap_practice_map_id = m.custom_gap_practice_map_id
     WHERE r.rn > 1;
END
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_custom_gap_practice_instance'
            AND object_id = OBJECT_ID('grac_practice.custom_gap_practice_map'))
    DROP INDEX ux_pm_custom_gap_practice_instance ON grac_practice.custom_gap_practice_map;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_custom_gap_practice_map_instance'
            AND object_id = OBJECT_ID('grac_practice.custom_gap_practice_map'))
    DROP INDEX ix_pm_custom_gap_practice_map_instance ON grac_practice.custom_gap_practice_map;
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_custom_gap_practice_map_instance')
    ALTER TABLE grac_practice.custom_gap_practice_map DROP CONSTRAINT fk_pm_custom_gap_practice_map_instance;
GO
IF COL_LENGTH('grac_practice.custom_gap_practice_map','practice_instance_key') IS NOT NULL
    ALTER TABLE grac_practice.custom_gap_practice_map DROP COLUMN practice_instance_key;
IF COL_LENGTH('grac_practice.custom_gap_practice_map','practice_instance_code') IS NOT NULL
    ALTER TABLE grac_practice.custom_gap_practice_map DROP COLUMN practice_instance_code;
IF COL_LENGTH('grac_practice.custom_gap_practice_map','practice_instance_name') IS NOT NULL
    ALTER TABLE grac_practice.custom_gap_practice_map DROP COLUMN practice_instance_name;
IF COL_LENGTH('grac_practice.custom_gap_practice_map','practice_instance_id') IS NOT NULL
    ALTER TABLE grac_practice.custom_gap_practice_map DROP COLUMN practice_instance_id;
GO
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'uq_pm_custom_gap_practice'
                AND parent_object_id = OBJECT_ID('grac_practice.custom_gap_practice_map'))
    ALTER TABLE grac_practice.custom_gap_practice_map
        ADD CONSTRAINT uq_pm_custom_gap_practice UNIQUE(custom_gap_id, practice_id);
GO

-- ---- exception_request_practice -------------------------------------
IF COL_LENGTH('grac_practice.exception_request_practice','practice_instance_id') IS NOT NULL
BEGIN
    ;WITH r AS (
        SELECT exception_request_practice_id,
               ROW_NUMBER() OVER (PARTITION BY exception_request_id, practice_id
                                  ORDER BY exception_request_practice_id) AS rn
          FROM grac_practice.exception_request_practice)
    DELETE x FROM grac_practice.exception_request_practice x
      JOIN r ON r.exception_request_practice_id = x.exception_request_practice_id
     WHERE r.rn > 1;
END
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_exception_request_practice_instance'
            AND object_id = OBJECT_ID('grac_practice.exception_request_practice'))
    DROP INDEX ux_pm_exception_request_practice_instance ON grac_practice.exception_request_practice;
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_exception_request_practice_instance')
    ALTER TABLE grac_practice.exception_request_practice DROP CONSTRAINT fk_pm_exception_request_practice_instance;
GO
IF COL_LENGTH('grac_practice.exception_request_practice','practice_instance_key') IS NOT NULL
    ALTER TABLE grac_practice.exception_request_practice DROP COLUMN practice_instance_key;
IF COL_LENGTH('grac_practice.exception_request_practice','practice_instance_code') IS NOT NULL
    ALTER TABLE grac_practice.exception_request_practice DROP COLUMN practice_instance_code;
IF COL_LENGTH('grac_practice.exception_request_practice','practice_instance_name') IS NOT NULL
    ALTER TABLE grac_practice.exception_request_practice DROP COLUMN practice_instance_name;
IF COL_LENGTH('grac_practice.exception_request_practice','practice_instance_id') IS NOT NULL
    ALTER TABLE grac_practice.exception_request_practice DROP COLUMN practice_instance_id;
GO
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'uq_pm_exception_request_practice'
                AND parent_object_id = OBJECT_ID('grac_practice.exception_request_practice'))
    ALTER TABLE grac_practice.exception_request_practice
        ADD CONSTRAINT uq_pm_exception_request_practice UNIQUE(exception_request_id, practice_id);
GO
PRINT '388 rolled back. Now re-run 387_risk_practice_instance_mapping.sql (restores sp_risk_treatment_state).';
GO
