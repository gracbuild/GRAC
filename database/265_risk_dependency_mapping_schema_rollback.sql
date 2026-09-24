-- =====================================================================
-- 265 Risk dependency mapping schema ROLLBACK
--
-- Reverses 265_risk_dependency_mapping_schema.sql: recreates the
-- asset-only tables, carries the Asset-category rows back into them, and
-- drops the generalised ones.
--
-- RUN 266's ROLLBACK FIRST. This file refuses while 266's procedures are
-- installed, because they read the tables it drops.
--
-- DATA LOSS WARNING -- READ THIS ONE
-- ----------------------------------
-- risk_asset_map can only hold ASSETS. Every dependency mapped in any
-- OTHER category -- applications, tools, vendors, processes, locations,
-- people, teams, committees -- is DROPPED and cannot be carried back,
-- because there is nowhere to put it. The count of what will be lost is
-- printed before the drop, and the drop proceeds anyway: a rollback that
-- silently discarded most of the mappings would be worse than one that
-- says so.
--
-- If those mappings matter, export risk_dependency_map before running
-- this file.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_risk_dependency_map_direct','P') IS NOT NULL
   OR OBJECT_ID('grac_practice.fn_risk_practice_dependencies','IF') IS NOT NULL
BEGIN
    PRINT 'ABORT (265-rollback): 266''s procedures are still installed and read the';
    PRINT '       tables this file drops. Run 266_risk_dependency_procs_rollback.sql first.';
    RAISERROR('265-rollback: run 266 rollback first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- What is about to be lost, named before it goes.
IF OBJECT_ID('grac_practice.risk_dependency_map','U') IS NOT NULL
BEGIN
    SELECT '265-rollback: mappings that CANNOT be carried back' AS Warning_,
           dt.dependency_type_name AS Category,
           COUNT(*)                AS RowsToBeDropped
      FROM grac_practice.risk_dependency_map m
      JOIN grac_practice.dependency_type_master dt
        ON dt.dependency_type_id = m.dependency_type_id
     WHERE dt.dependency_type_code <> N'Asset'
     GROUP BY dt.dependency_type_name
     ORDER BY COUNT(*) DESC;
END
GO

-- ---------------------------------------------------------------------
-- Recreate the asset-only tables (261's definitions, verbatim)
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.risk_asset_map','U') IS NULL
CREATE TABLE grac_practice.risk_asset_map(
    risk_asset_map_id     BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_asset_map PRIMARY KEY,
    organization_id       BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_asset_map_org
            REFERENCES grac_practice.organization(organization_id),
    risk_register_id      BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_asset_map_register
            REFERENCES grac_practice.risk_register(risk_register_id),
    asset_id              BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_asset_map_asset
            REFERENCES grac_practice.organization_dependency_asset(asset_id),
    asset_name            NVARCHAR(220) NULL,
    first_mapped_dt       DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_asset_map_dt DEFAULT SYSUTCDATETIME(),
    mapped_by_employee_id BIGINT NULL
        CONSTRAINT fk_pm_risk_asset_map_mapper
            REFERENCES grac_practice.organization_employee(employee_id),
    remarks               NVARCHAR(1000) NULL,
    record_status_id      INT NOT NULL
        CONSTRAINT fk_pm_risk_asset_map_record_status
            REFERENCES grac_practice.record_status_master(record_status_id),
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_risk_asset_map_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_asset_map_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,
    CONSTRAINT uq_pm_risk_asset_map UNIQUE(risk_register_id, asset_id)
);
GO

IF OBJECT_ID('grac_practice.risk_asset_map_source','U') IS NULL
CREATE TABLE grac_practice.risk_asset_map_source(
    risk_asset_map_source_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_asset_map_source PRIMARY KEY,
    risk_asset_map_id     BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_asset_src_map
            REFERENCES grac_practice.risk_asset_map(risk_asset_map_id),
    source_kind_code      NVARCHAR(30) NOT NULL,
    practice_id           BIGINT NULL
        CONSTRAINT fk_pm_risk_asset_src_practice
            REFERENCES grac_practice.practice(practice_id),
    practice_instance_id  BIGINT NULL
        CONSTRAINT fk_pm_risk_asset_src_instance
            REFERENCES grac_practice.practice_instance(practice_instance_id),
    resolution_id         BIGINT NULL,
    added_dt              DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_asset_src_dt DEFAULT SYSUTCDATETIME(),
    added_by_employee_id  BIGINT NULL
        CONSTRAINT fk_pm_risk_asset_src_adder
            REFERENCES grac_practice.organization_employee(employee_id),
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_risk_asset_src_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_asset_src_entered_dt DEFAULT SYSUTCDATETIME(),
    practice_key  AS (ISNULL(practice_id, CAST(0 AS BIGINT))) PERSISTED,
    instance_key  AS (ISNULL(practice_instance_id, CAST(0 AS BIGINT))) PERSISTED,
    CONSTRAINT ck_pm_risk_asset_src_kind
        CHECK (source_kind_code IN (N'PracticeDependency', N'Direct')),
    CONSTRAINT ck_pm_risk_asset_src_practice_present
        CHECK (source_kind_code <> N'PracticeDependency' OR practice_id IS NOT NULL),
    CONSTRAINT ck_pm_risk_asset_src_direct_practice
        CHECK (source_kind_code <> N'Direct' OR practice_id IS NULL),
    CONSTRAINT uq_pm_risk_asset_map_source
        UNIQUE(risk_asset_map_id, source_kind_code, practice_key, instance_key)
);
GO

-- ---------------------------------------------------------------------
-- Carry the Asset-category rows back
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.risk_dependency_map','U') IS NOT NULL
BEGIN
    DECLARE @asset_type_id INT =
        (SELECT TOP 1 dependency_type_id FROM grac_practice.dependency_type_master
          WHERE dependency_type_code = N'Asset' OR dependency_type_name = N'Asset'
          ORDER BY dependency_type_id);

    DECLARE @back INT = 0;

    BEGIN TRY
        BEGIN TRAN;

        INSERT INTO grac_practice.risk_asset_map
            (organization_id, risk_register_id, asset_id, asset_name,
             first_mapped_dt, mapped_by_employee_id, remarks,
             record_status_id, entered_by, entered_dt, updated_by, updated_dt)
        SELECT m.organization_id, m.risk_register_id, m.dependency_object_id,
               LEFT(m.dependency_object_name, 220),
               m.first_mapped_dt, m.mapped_by_employee_id, m.remarks,
               m.record_status_id, m.entered_by, m.entered_dt, m.updated_by, m.updated_dt
          FROM grac_practice.risk_dependency_map m
         WHERE m.dependency_type_id = @asset_type_id
           -- The FK to organization_dependency_asset is back, so only
           -- objects that really are assets can return. Anything else
           -- would fail the insert and take the whole rollback with it.
           AND EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                        WHERE a.asset_id = m.dependency_object_id)
           AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_asset_map x
                            WHERE x.risk_register_id = m.risk_register_id
                              AND x.asset_id = m.dependency_object_id);

        SET @back = @@ROWCOUNT;

        INSERT INTO grac_practice.risk_asset_map_source
            (risk_asset_map_id, source_kind_code, practice_id,
             practice_instance_id, resolution_id,
             added_dt, added_by_employee_id, entered_by, entered_dt)
        SELECT a.risk_asset_map_id, s.source_kind_code, s.practice_id,
               s.practice_instance_id, s.resolution_id,
               s.added_dt, s.added_by_employee_id, s.entered_by, s.entered_dt
          FROM grac_practice.risk_dependency_map_source s
          JOIN grac_practice.risk_dependency_map m
            ON m.risk_dependency_map_id = s.risk_dependency_map_id
           AND m.dependency_type_id = @asset_type_id
          JOIN grac_practice.risk_asset_map a
            ON a.risk_register_id = m.risk_register_id
           AND a.asset_id         = m.dependency_object_id
         WHERE NOT EXISTS (
                 SELECT 1 FROM grac_practice.risk_asset_map_source x
                  WHERE x.risk_asset_map_id = a.risk_asset_map_id
                    AND x.source_kind_code = s.source_kind_code
                    AND x.practice_key = ISNULL(s.practice_id, CAST(0 AS BIGINT))
                    AND x.instance_key = ISNULL(s.practice_instance_id, CAST(0 AS BIGINT)));

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    PRINT CONCAT('265-rollback: carried ', @back, ' asset mapping(s) back. ',
                 'Every non-Asset mapping is being dropped -- see the warning above.');
END
GO

IF OBJECT_ID('grac_practice.risk_dependency_map_source','U') IS NOT NULL
    DROP TABLE grac_practice.risk_dependency_map_source;
GO
IF OBJECT_ID('grac_practice.risk_dependency_map','U') IS NOT NULL
    DROP TABLE grac_practice.risk_dependency_map;
GO

SELECT '265 rollback complete' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.risk_dependency_map','U') IS NULL
             AND OBJECT_ID('grac_practice.risk_asset_map','U')      IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '265-rollback done.';
PRINT '     NEXT: re-run 262_risk_mapping_procs.sql (restores the asset-only procs)';
PRINT '           and 264_risk_acceptance_review_procs.sql (restores list/get with';
PRINT '           MappedAssetCount instead of MappedDependencyCount).';
GO

SET NOEXEC OFF;
GO
