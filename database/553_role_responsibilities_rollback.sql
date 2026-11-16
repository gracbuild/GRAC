-- =====================================================================
-- 553 ROLLBACK -- restores the 465 sp_org_role_save / sp_org_role_list and
-- drops the 553 procedures. role_responsibility_master and
-- organization_role_responsibility are KEPT (unread). Deploy the pre-553
-- Api and Web with it. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_org_role_save
    @p_payload NVARCHAR(MAX),
    @p_id      BIGINT = 0,
    @p_usr_id  NVARCHAR(100) = 'system',
    @out_id    BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Same derivation the monolith does at the top of its save, so the
    -- status a role ends up on is identical either side of this boundary.
    DECLARE @active_record_status_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = 'Active');
    DECLARE @payload_record_status_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master
          WHERE status_code = JSON_VALUE(@p_payload,'$.status') OR status_name = JSON_VALUE(@p_payload,'$.status'));
    DECLARE @payload_record_status_id_from_id INT = TRY_CONVERT(INT, NULLIF(JSON_VALUE(@p_payload,'$.statusId'),''));
    SET @payload_record_status_id = COALESCE(@payload_record_status_id_from_id, @payload_record_status_id);

    DECLARE @role_org_id BIGINT       = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
    DECLARE @role_name   NVARCHAR(120)= NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.roleName'))),'');
    -- 465. NULL, not '': ux_pm_org_role_code is filtered on
    -- role_code IS NOT NULL AND role_code <> '', so storing '' for "no
    -- code" would be outside the index on some rows and inside it on
    -- others. NULL keeps every blank out of it, so any number of roles
    -- may carry no code. NVARCHAR(60) matches the column from 027.
    DECLARE @role_code   NVARCHAR(60) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.roleCode'))),'');

    -- ---- the monolith's validation, unchanged and in the same order ----
    IF @role_org_id IS NULL THROW 51140,'Organization is required for Role.',1;
    IF @role_name IS NULL THROW 51141,'Role Name is required.',1;
    IF EXISTS(SELECT 1 FROM grac_practice.organization_role
               WHERE organization_id = @role_org_id AND LOWER(role_name) = LOWER(@role_name)
                 AND (@p_id = 0 OR role_id <> @p_id))
        THROW 51142,'Role Name already exists for this organization.',1;

    -- ---- 465 validation ----
    -- The friendly form of the ux_pm_org_role_code violation. 51150 is
    -- the number PracticeRepositoryService already maps to the roleCode
    -- field, so this error lands on the Role Code input instead of
    -- reaching the operator as a bare index error. Only checked when a
    -- code was actually supplied -- blanks are NULL and the index
    -- ignores them.
    IF @role_code IS NOT NULL
       AND EXISTS(SELECT 1 FROM grac_practice.organization_role
                   WHERE organization_id = @role_org_id AND LOWER(role_code) = LOWER(@role_code)
                     AND (@p_id = 0 OR role_id <> @p_id))
        THROW 51150,'Role Code already exists for this organization.',1;

    IF @p_id = 0
    BEGIN
        INSERT grac_practice.organization_role
            (organization_id, role_name, role_code, description,
             status, record_status_id, entered_by)
        VALUES
            (@role_org_id, @role_name, @role_code, JSON_VALUE(@p_payload,'$.description'),
             COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),
             COALESCE(@payload_record_status_id, @active_record_status_id), @p_usr_id);
        SET @out_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_role
           SET organization_id  = @role_org_id,
               role_name        = @role_name,
               role_code        = @role_code,
               description      = JSON_VALUE(@p_payload,'$.description'),
               status           = COALESCE(JSON_VALUE(@p_payload,'$.status'), status),
               record_status_id = COALESCE(@payload_record_status_id, record_status_id),
               updated_by       = @p_usr_id,
               updated_dt       = SYSUTCDATETIME()
         WHERE role_id = @p_id;
        SET @out_id = @p_id;
    END
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_role_list
    @p_id            BIGINT = 0,
    @organization_id BIGINT = NULL,
    @p_status        NVARCHAR(30) = '',
    @p_search        NVARCHAR(250) = '',
    @p_page_number   INT = 1,
    @p_page_size     INT = 25
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @filter_record_status_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master
          WHERE status_code = @p_status OR status_name = @p_status);
    DECLARE @offset INT = (CASE WHEN @p_page_number < 1 THEN 1 ELSE @p_page_number END - 1)
                          * CASE WHEN @p_page_size < 1 THEN 25 ELSE @p_page_size END;
    DECLARE @page_size INT = CASE WHEN @p_page_size < 1 THEN 25 ELSE @p_page_size END;

    SELECT r.role_id Id, r.organization_id OrganizationId, o.organization_name Organization,
           r.role_code RoleCode,                       -- 465: was absent entirely
           r.role_name RoleName, r.description Description,
           r.record_status_id StatusId, rs.status_name Status,
           COUNT(*) OVER () AS TotalRows
    FROM   grac_practice.organization_role r
    JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
    JOIN   grac_practice.record_status_master rs ON rs.record_status_id = r.record_status_id
    WHERE  (@p_id = 0 OR r.role_id = @p_id)
      AND  (@organization_id IS NULL OR r.organization_id = @organization_id)
      AND  (@p_status = '' OR r.record_status_id = @filter_record_status_id)
      -- 465: role_code joins the searchable fields. The column is on the
      -- grid, and a column you can see but not search reads as broken.
      AND  (@p_search = '' OR r.role_name LIKE '%'+@p_search+'%'
                           OR ISNULL(r.role_code,'') LIKE '%'+@p_search+'%'
                           OR ISNULL(r.description,'') LIKE '%'+@p_search+'%')
    ORDER  BY r.role_name
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

IF OBJECT_ID('grac_practice.sp_get_role_responsibility_lookup','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_get_role_responsibility_lookup;
GO
IF OBJECT_ID('grac_practice.sp_org_responsibility_holder_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_responsibility_holder_list;
GO
PRINT '553 rolled back (procedures). Tables kept.';
GO
