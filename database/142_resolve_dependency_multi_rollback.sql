-- =====================================================================
-- 142 -- ROLLBACK: back to one object per save
--
-- Restores the single-object sp_resolve_dependency_save from 141 and
-- drops sp_resolve_dependency_remove.
--
-- No data is touched. Resolutions already created stay exactly as they
-- are, including categories that hold several objects -- the unique
-- constraint always allowed that, so nothing here is invalid afterwards.
-- What goes is the ability to add several at once, and to remove one:
-- after this rollback a wrongly resolved object can only be deactivated
-- through the Registers workbench.
--
-- Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_resolve_dependency_remove','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_resolve_dependency_remove;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_dependency_save
    @practice_instance_id   BIGINT,
    @dependency_type_id     INT,
    @resolved_dependency_id BIGINT,
    @resolved_name          NVARCHAR(300),
    @resolution_owner_id    BIGINT       = NULL,
    @remarks                NVARCHAR(MAX) = NULL,
    @actor                  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL OR @dependency_type_id IS NULL OR @resolved_dependency_id IS NULL
        THROW 52614, 'sp_resolve_dependency_save: instance, dependency type and resolved object are all required.', 1;
    IF NULLIF(LTRIM(RTRIM(ISNULL(@resolved_name, N''))), N'') IS NULL
        THROW 52615, 'sp_resolve_dependency_save: the resolved object name is required.', 1;

    DECLARE @organization_id BIGINT;
    SELECT @organization_id = organization_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;
    IF @organization_id IS NULL
        THROW 52616, 'sp_resolve_dependency_save: instance not found.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance_dependency d
                    WHERE d.practice_instance_id = @practice_instance_id
                      AND d.dependency_type_id   = @dependency_type_id
                      AND d.status = N'Active')
        THROW 52617, 'sp_resolve_dependency_save: this instance does not declare that dependency category.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
    DECLARE @resolved_status_id INT = (
        SELECT TOP 1 resolution_status_id FROM grac_practice.dependency_resolution_status_master
        WHERE status_code = N'Resolved' ORDER BY resolution_status_id);
    IF @resolved_status_id IS NULL
        THROW 52618, 'sp_resolve_dependency_save: Resolved dependency status is missing.', 1;

    DECLARE @category NVARCHAR(120) = (
        SELECT TOP 1 COALESCE(dt.dependency_type_name, d.dependency_type)
        FROM   grac_practice.practice_instance_dependency d
        LEFT   JOIN grac_practice.dependency_type_master dt
               ON dt.dependency_type_id = d.dependency_type_id
        WHERE  d.practice_instance_id = @practice_instance_id
          AND  d.dependency_type_id   = @dependency_type_id);

    BEGIN TRAN;

    MERGE grac_practice.practice_dependency_resolution AS target
    USING (SELECT @organization_id AS organization_id,
                  @practice_instance_id AS practice_instance_id,
                  @dependency_type_id AS dependency_type_id,
                  @resolved_dependency_id AS resolved_dependency_id) AS src
       ON target.organization_id        = src.organization_id
      AND target.practice_instance_id   = src.practice_instance_id
      AND target.dependency_type_id     = src.dependency_type_id
      AND target.resolved_dependency_id = src.resolved_dependency_id
    WHEN MATCHED THEN UPDATE SET
        resolved_dependency_name = @resolved_name,
        resolution_status_id     = @resolved_status_id,
        resolution_status        = N'Resolved',
        resolution_owner_id      = @resolution_owner_id,
        resolution_dt            = SYSUTCDATETIME(),
        remarks                  = @remarks,
        is_active                = 1,
        record_status_id         = @active_record_status_id,
        updated_by               = @actor,
        updated_dt               = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (organization_id, practice_instance_id, dependency_type_id, dependency_category,
         resolved_dependency_id, resolved_dependency_name, resolution_status_id,
         resolution_status, resolution_owner_id, resolution_dt, remarks,
         is_active, record_status_id, entered_by)
    VALUES
        (@organization_id, @practice_instance_id, @dependency_type_id, ISNULL(@category, N'Dependency'),
         @resolved_dependency_id, @resolved_name, @resolved_status_id,
         N'Resolved', @resolution_owner_id, SYSUTCDATETIME(), @remarks,
         1, @active_record_status_id, @actor);

    COMMIT TRAN;

    SELECT CAST(1 AS BIT) AS Success,
           N'Dependency resolved.' AS Message,
           (SELECT COUNT(*) FROM grac_practice.practice_dependency_resolution
             WHERE practice_instance_id = @practice_instance_id AND is_active = 1) AS ResolvedCount;
END
GO

SELECT 'single-object signature restored' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters p
                          WHERE p.object_id = OBJECT_ID('grac_practice.sp_resolve_dependency_save')
                            AND p.name = '@resolved_dependency_id')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'remove procedure dropped',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_dependency_remove','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '142 rolled back. Existing multi-object resolutions were left untouched.';
GO
