-- =====================================================================
-- 556 ROLLBACK -- restores sp_org_assurance_execution_live_scope as 555
-- issued it (no @mode). Deploy the pre-556 Api and Web with it.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_live_scope
    @organization_id BIGINT,
    @execution_id    BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL OR @execution_id IS NULL
        THROW 54009, 'organization_id and execution_id are required.', 1;

    DECLARE @def BIGINT, @ver BIGINT, @item BIGINT, @frozen DATETIME2;
    SELECT @def    = e.org_assurance_definition_id,
           @ver    = e.org_assurance_definition_version_id,
           @item   = e.org_assurance_plan_item_id,
           @frozen = e.scope_frozen_at
      FROM grac_practice.org_assurance_execution e
     WHERE e.org_assurance_execution_id = @execution_id
       AND e.organization_id = @organization_id
       AND e.is_active = 1;
    IF @def IS NULL
        THROW 54010, 'Execution not found or not accessible in this organization.', 1;

    IF @frozen IS NOT NULL
    BEGIN
        SELECT ee.dimension_code AS DimensionCode, ee.dimension_name AS DimensionName,
               ee.entity_id AS EntityId, ee.entity_code AS EntityCode, ee.entity_name AS EntityName
          FROM grac_practice.org_assurance_execution_entity ee
         WHERE ee.org_assurance_execution_id = @execution_id
           AND ee.organization_id = @organization_id
           AND ee.is_active = 1
         ORDER BY ee.dimension_code, ee.entity_name, ee.entity_code;
        RETURN;
    END

    DECLARE @branch BIGINT = (SELECT assigned_branch_id FROM grac_practice.org_assurance_plan_item
                               WHERE org_assurance_plan_item_id = @item);
    DECLARE @ents TABLE (dimension_code NVARCHAR(60) NULL, dimension_name NVARCHAR(160) NULL,
                         entity_id BIGINT NULL, entity_code NVARCHAR(120) NULL, entity_name NVARCHAR(240) NULL);
    DECLARE @res BIGINT;

    BEGIN TRAN;
    EXEC grac_practice.sp_org_assurance_scope_resolve
         @organization_id    = @organization_id,
         @definition_id      = @def,
         @version_id         = @ver,
         @resolution_purpose = N'PREVIEW',
         @execution_id       = NULL,
         @actor              = @actor,
         @resolution_id_out  = @res OUTPUT;
    IF @branch IS NOT NULL
        EXEC grac_practice.sp_org_assurance_scope_resolution_narrow_location
             @organization_id = @organization_id,
             @resolution_id   = @res,
             @location_id     = @branch;
    INSERT INTO @ents (dimension_code, dimension_name, entity_id, entity_code, entity_name)
    SELECT DISTINCT r.dimension_code, r.dimension_name, r.entity_id, r.entity_code, r.entity_name
      FROM grac_practice.org_assurance_scope_resolution_entity r
     WHERE r.org_assurance_scope_resolution_id = @res;
    ROLLBACK;   -- live: nothing the resolver wrote is kept

    SELECT dimension_code AS DimensionCode, dimension_name AS DimensionName,
           entity_id AS EntityId, entity_code AS EntityCode, entity_name AS EntityName
      FROM @ents
     ORDER BY dimension_code, entity_name, entity_code;
END
GO

PRINT '556 rolled back.';
GO
